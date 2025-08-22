# frozen_string_literal: true

require_relative '../missive/post_builder'
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
      rows.sort_by! { |ts| QuickbooksTime::Missive::PostBuilder.compute_times(ts).last || Time.at(0) }
      rows.each do |ts|
        changed, old_post_id = @ts_repo.upsert(ts)
        next unless changed

        ts['jobsite_name'] ||= @jobs_repo.name(ts['jobcode_id'] || ts['quickbooks_time_jobsite_id'])
        ts['user_name']    ||= @users_repo.name(ts['user_id'])

        touched[ts['jobcode_id']] = true
        QuickbooksTime::Missive::Queue.enqueue_delete(old_post_id) if old_post_id
        payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
        Array(payloads).each do |payload|
          QuickbooksTime::Missive::Queue.enqueue_post(payload, timesheet_id: ts['id'])
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
