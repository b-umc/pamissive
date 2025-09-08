# frozen_string_literal: true

require_relative '../missive/task_builder'
require 'ostruct'
require_relative '../missive/queue'
require_relative '../streams/timesheet_stream'
require_relative '../missive/summary_queue'
require_relative 'overview_refresher'
require_relative 'summary_poster'

class TimesheetsSyncer
  def initialize(qbt, repos, cursor)
    @stream    = TimesheetStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @ts_repo   = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
    @repos = repos
    @summary_poster = SummaryPoster.new(OpenStruct.new(timesheets: @ts_repo, jobs: @jobs_repo, users: @users_repo))
  end

  def backfill_all(&done)
    touched = {}
    @stream.each_batch(proc do |rows|
      rows.sort_by! { |ts| QuickbooksTime::Missive::TaskBuilder.compute_times(ts).last || Time.at(0) }
      rows.each do |ts|
        changed, old_task_ids = @ts_repo.upsert(ts)
        next unless changed

        touched[ts['jobcode_id']] = true

        if Constants::MISSIVE_USE_TASKS
          # If old task IDs exist, this is an update, not a delete/recreate.
          if old_task_ids && !old_task_ids.empty?
            ts['user_name'] ||= @users_repo.name(ts['user_id'])
            ts['jobsite_name'] ||= @jobs_repo.name(ts['jobcode_id'])

            update_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)

            QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:user_task_id], update_payload)
            QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:jobsite_task_id], update_payload)

            # Enqueue summaries for both conversations for the affected date.
            begin
              row = @ts_repo.find(ts['id'])
              if row
                if row['missive_user_task_conversation_id']
                  QuickbooksTime::Missive::SummaryQueue.enqueue(
                    conversation_id: row['missive_user_task_conversation_id'],
                    type: :user,
                    date: ts['date']
                  )
                end
                if row['missive_jobsite_task_conversation_id']
                  QuickbooksTime::Missive::SummaryQueue.enqueue(
                    conversation_id: row['missive_jobsite_task_conversation_id'],
                    type: :job,
                    date: ts['date']
                  )
                end
              end
            rescue => e
              LOG.error [:summary_enqueue_on_update_error, e.class, e.message]
            end
          end
        else
          # Summary-only mode: post a fresh summary for user (with notify) and job (silent)
          begin
            # Optionally defer live summary updates during a full resync to avoid churn
            if Constants::MISSIVE_DEFER_DURING_FULL_RESYNC && (ENV['QBT_FULL_RESYNC'] == '1')
              next
            end
            # Also respect global live updates switch
            next unless Constants::MISSIVE_LIVE_UPDATES
            uid = ts['user_id']
            jid = ts['jobcode_id'] || ts['quickbooks_time_jobsite_id']
            date_s = ts['date']

            notify = build_notify(ts, action: (old_task_ids && !old_task_ids.empty?) ? 'updated' : 'added')
            @summary_poster.post_user(user_id: uid, date: date_s, notify: notify) { }
            @summary_poster.post_job(job_id: jid, date: date_s, notify: nil) { }
          rescue => e
            LOG.error [:summary_post_error, e.class, e.message]
          end
        end
      end
      # Kick the Missive queue after enqueuing updates (rate-limited inside)
      QuickbooksTime::Missive::Queue.drain_global(repo: @ts_repo)
    end) do |ok|
      if ok
        OverviewRefresher.rebuild_many(touched.keys) { done&.call(true) }
      else
        done&.call(false)
      end
    end
  rescue StandardError => e
    LOG.error [:timesheet_sync_failed, e.message]
    done&.call(false)
  end

  private

  def build_notify(ts, action: 'updated')
    user = ts['user_name'] || @users_repo.name(ts['user_id']) || "User #{ts['user_id']}"
    job  = ts['jobsite_name'] || @jobs_repo.name(ts['jobcode_id'] || ts['quickbooks_time_jobsite_id']) || "Job #{ts['jobcode_id'] || ts['quickbooks_time_jobsite_id']}"
    secs = (ts['duration_seconds'] || ts['duration'] || 0).to_i
    hours = format('%.2f', secs / 3600.0)
    title = "Timesheet #{action} • #{ts['date']}"
    body  = "#{user} @ #{job} — #{hours}h"
    { title: title, body: body }
  rescue
    { title: "Timesheet #{action}", body: ts['date'].to_s }
  end
end
