# frozen_string_literal: true

require_relative '../missive/task_builder'
require_relative '../missive/queue'
require_relative '../streams/timesheet_stream'
require_relative 'overview_refresher'

class TimesheetsSyncer
  def initialize(qbt, repos, cursor)
    @stream    = TimesheetStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @ts_repo   = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
  end

  def backfill_all(&done)
    touched = {}
    @stream.each_batch(proc do |rows|
      rows.sort_by! { |ts| QuickbooksTime::Missive::TaskBuilder.compute_times(ts).last || Time.at(0) }
      rows.each do |ts|
        changed, old_task_ids = @ts_repo.upsert(ts)
        next unless changed

        touched[ts['jobcode_id']] = true
        
        # If old task IDs exist, this is an update, not a delete/recreate.
        if old_task_ids && !old_task_ids.empty?
          ts['user_name'] ||= @users_repo.name(ts['user_id'])
          ts['jobsite_name'] ||= @jobs_repo.name(ts['jobcode_id'])
          
          update_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
          
          QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:user_task_id], update_payload)
          QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:jobsite_task_id], update_payload)
        end
      end
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
end
