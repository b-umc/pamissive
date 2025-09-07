# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../missive/client'
require_relative '../missive/task_builder'
require_relative '../missive/summary_queue'
require_relative '../missive/summary_queue'
require_relative '../util/constants'
require_relative '../../../nonblock_socket/select_controller'

class QuickbooksTime
  class MissiveTaskVerifier
    include TimeoutInterface

    def initialize(repos)
      @repos = repos
      @client = QuickbooksTime::Missive::Client.new
    end

    # Fetch current state from Missive and reconcile deterministically.
    def run(&done)
      rows = @repos.timesheets.tasks_with_task_ids_recent(lookback_minutes: Constants::MISSIVE_VERIFY_LOOKBACK_MIN)
      LOG.debug [:missive_verify_scan, :count, rows.length]

      process = proc do
        row = rows.shift
        if row.nil?
          # Mark a verification checkpoint so summary queue can drain safely
          begin
            QuickbooksTime::Missive::SummaryQueue.verify_completed!
          rescue StandardError
            # ignore
          end
          done&.call(true)
          next
        end

        verify_one(row) { add_timeout(process, 0) }
      end

      process.call
    rescue => e
      LOG.error [:missive_verify_error, e.class, e.message]
      done&.call(false)
    end

    private

    def verify_one(ts)
      desired_state = QuickbooksTime::Missive::TaskBuilder.determine_task_state(ts)
      user_id = ts['missive_user_task_id']
      job_id  = ts['missive_jobsite_task_id']
      user_conv = ts['missive_user_task_conversation_id']
      job_conv  = ts['missive_jobsite_task_conversation_id']

      left = [user_id && user_conv, job_id && job_conv].compact.size
      return yield if left.zero?

      join = proc { left -= 1; yield if left.zero? }

      fetch_and_reconcile(ts, user_id, user_conv, desired_state, :user, &join) if user_id && user_conv
      fetch_and_reconcile(ts, job_id,  job_conv,  desired_state, :job,  &join) if job_id && job_conv
    end

    def fetch_and_reconcile(ts, task_id, conversation_id, desired_state, type, &done)
      @client.get_conversation_comments(conversation_id, limit: 10) do |status, _hdrs, body|
        if (200..299).include?(status)
          # Body: { "comments": [ { ..., "task": { state: ... } }, ... ] }
          remote_state = nil
          LOG.debug [:missive_verify_fetch_comments, ts['id'], :task, task_id, :conv, conversation_id, :status, status, :body_type, (body.class.name rescue 'nil')]
          if body.is_a?(Hash)
            comments = body['comments'] || []
            #tasks = comments.map { |c| c['task'] }.compact
            #states = tasks.map { |t| t['state'] }.compact
            #LOG.debug [
            #  :missive_verify_comments_overview,
            #  ts['id'], :task, task_id, :conv, conversation_id,
            #  :comments, comments.size, :with_task, tasks.size, :with_state, states.size,
            #  :task_ids, tasks.map { |t| t['id'] rescue nil },
            #  :states, states,
            #  :notes, comments.map{|c| [c['body'], c['id']]}
            #]
            # Missive comments use 'description' to carry the task title.
            # Prefer matching by hidden marker embedded in the title; fall back to title compare.
            #begin
            #  expected_title = QuickbooksTime::Missive::TaskBuilder.build_task_title(ts)
            #rescue StandardError
            #  expected_title = nil
            #end
            tsid = (ts['id'] || ts[:id]).to_s
            found = comments.find do |c|
              t = c['task']
              next false unless t && t['state']
              desc_title = t['description'].to_s

              expected_title = "qbt:#{tsid}"
              LOG.debug([desc_title, expected_title])
              desc_title.include?(expected_title)
              #embedded = QuickbooksTime::Missive::TaskBuilder.extract_id_from_title(desc_title)
              #if embedded
              #  embedded.to_s == tsid
              #else
              #  expected_title && (desc_title == expected_title || desc_title.include?(expected_title))
              #end
            end
            remote_state = found && found['task']['state']
            #unless remote_state
              LOG.debug [
                :missive_verify_no_remote_state,
                ts['id'], :task, task_id, :conv, conversation_id,
                :desired, desired_state,
                :matching_comment_found, !!found
              ]
            #end
          else
            LOG.debug [:missive_verify_unexpected_body, ts['id'], :task, task_id, :conv, conversation_id, :body, (body.inspect rescue 'uninspectable')]
          end
          if remote_state
            # Persist observed remote state only if it changed to avoid
            # bumping updated_at unnecessarily (which would keep the row
            # inside the recent lookback window forever).
            current = (type == :user) ? ts['missive_user_task_state'] : ts['missive_jobsite_task_state']
            if current != remote_state
              if type == :user
                @repos.timesheets.update_user_task_state(ts['id'], remote_state)
              else
                @repos.timesheets.update_job_task_state(ts['id'], remote_state)
              end
            end
          end

          # Enqueue an update if state mismatches OR (once) for deleted rows
          # where our recorded side isn't already the desired state.
          state_mismatch = remote_state && remote_state != desired_state
          recorded_for_side = (type == :user) ? ts['missive_user_task_state'] : ts['missive_jobsite_task_state']
          needs_deleted_propagation = QuickbooksTime::Missive::TaskBuilder.deleted?(ts) && (recorded_for_side.nil? || recorded_for_side != desired_state)
          if state_mismatch || needs_deleted_propagation
            payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
            QuickbooksTime::Missive::Queue.enqueue_update_task(task_id, payload)
            QuickbooksTime::Missive::Queue.drain_global(repo: @repos.timesheets)
            LOG.info [:missive_verify_enqueue_update, ts['id'], task_id, :from, remote_state, :to, desired_state, :deleted, QuickbooksTime::Missive::TaskBuilder.deleted?(ts), :recorded, recorded_for_side]
            # Also enqueue summary for this conversation/date
            begin
              QuickbooksTime::Missive::SummaryQueue.enqueue(
                conversation_id: conversation_id,
                type: type,
                date: ts['date']
              )
            rescue => e
              LOG.error [:summary_enqueue_on_verify_error, e.class, e.message]
            end
          else
            LOG.debug [:missive_verify_ok, ts['id'], task_id, :state, remote_state]
          end
        else
          LOG.error [:missive_verify_get_failed, ts['id'], task_id, :status, status]
        end
        done.call
      end
    end
  end
end
