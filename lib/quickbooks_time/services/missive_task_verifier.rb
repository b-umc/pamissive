# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../missive/client'
require_relative '../missive/task_builder'
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
          if body.is_a?(Hash)
            comments = body['comments'] || []
            comments.each do |c|
              t = c['task']
              if t && t['state']
                remote_state = t['state']
                break
              end
            end
          end
          if remote_state
            # Persist the observed remote state so our next selection is accurate
            if type == :user
              @repos.timesheets.update_user_task_state(ts['id'], remote_state)
            else
              @repos.timesheets.update_job_task_state(ts['id'], remote_state)
            end
          end

          if remote_state && remote_state != desired_state
            payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
            QuickbooksTime::Missive::Queue.enqueue_update_task(task_id, payload)
            LOG.info [:missive_verify_enqueue_update, ts['id'], task_id, :from, remote_state, :to, desired_state]
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
