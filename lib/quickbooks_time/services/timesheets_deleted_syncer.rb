# frozen_string_literal: true

require_relative '../streams/timesheets_deleted_stream'
require_relative '../missive/queue'
require_relative '../missive/summary_queue'
require_relative '../util/constants'
require_relative 'summary_poster'
require 'ostruct'
require_relative 'overview_refresher'
require_relative '../../../logging/app_logger'

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class TimesheetsDeletedSyncer
  def initialize(qbt, repos, cursor)
    @stream    = TimesheetsDeletedStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @ts_repo   = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
    @summary_poster = SummaryPoster.new(OpenStruct.new(timesheets: @ts_repo, jobs: @jobs_repo, users: @users_repo))
  end

  def run(&done)
    touched = {}

    handle_rows = proc do |rows|
      rows.each do |row|
        id = (row['id'] || row[:id]).to_i
        next if id <= 0

        # Mark as deleted locally and update Missive tasks to closed + annotated
        existing = @ts_repo.find(id)
        @ts_repo.mark_deleted(id, row['last_modified'] || row['modified'] || row['deleted'] || row['deleted_at'])

        if existing
          touched[existing['quickbooks_time_jobsite_id']] = true
          begin
            ts = existing.dup
            ts['deleted'] = true
            # Enrich minimal fields for title building if missing
            ts['user_name'] ||= @users_repo&.name(ts['user_id']) if defined?(@users_repo)
            ts['jobsite_name'] ||= @jobs_repo&.name(ts['quickbooks_time_jobsite_id'])

            if Constants::MISSIVE_USE_TASKS
              update_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
              if existing['missive_user_task_id']
                QuickbooksTime::Missive::Queue.enqueue_update_task(existing['missive_user_task_id'], update_payload)
              end
              if existing['missive_jobsite_task_id']
                QuickbooksTime::Missive::Queue.enqueue_update_task(existing['missive_jobsite_task_id'], update_payload)
              end
              QuickbooksTime::Missive::Queue.drain_global(repo: @ts_repo)

              # Enqueue summary updates for the day
              begin
                if existing['missive_user_task_conversation_id']
                  QuickbooksTime::Missive::SummaryQueue.enqueue(
                    conversation_id: existing['missive_user_task_conversation_id'],
                    type: :user,
                    date: existing['date']
                  )
                end
                if existing['missive_jobsite_task_conversation_id']
                  QuickbooksTime::Missive::SummaryQueue.enqueue(
                    conversation_id: existing['missive_jobsite_task_conversation_id'],
                    type: :job,
                    date: existing['date']
                  )
                end
              rescue => e
                LOG.warn [:summary_enqueue_on_delete_failed, id, e.message]
              end
            else
              # Summary-only mode: post fresh summaries (user with notify, job silent)
              begin
                if Constants::MISSIVE_DEFER_DURING_FULL_RESYNC && (ENV['QBT_FULL_RESYNC'] == '1')
                  next
                end
                next unless Constants::MISSIVE_LIVE_UPDATES
                uid = ts['user_id']
                jid = ts['quickbooks_time_jobsite_id']
                date_s = ts['date']
                notify = { title: "Timesheet deleted • #{date_s}", body: "#{ts['user_name']} @ #{ts['jobsite_name']}" }
                @summary_poster.post_user(user_id: uid, date: date_s, notify: notify) { }
                @summary_poster.post_job(job_id: jid, date: date_s, notify: nil) { }
              rescue => e
                LOG.warn [:summary_post_on_delete_failed, id, e.message]
              end
            end
          rescue StandardError => e
            LOG.warn [:timesheet_delete_update_failed, id, e.message]
          end
        end
      end
    end

    @stream.each_batch(handle_rows) do |ok|
      if ok
        OverviewRefresher.rebuild_many(touched.keys) { done&.call(true) }
      else
        done&.call(false)
      end
    end
  rescue => e
    LOG.error [:timesheets_deleted_sync_failed, e.class, e.message]
    done&.call(false)
  end
end
