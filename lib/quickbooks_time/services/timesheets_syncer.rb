# frozen_string_literal: true

require_relative '../missive/post_builder'
require_relative '../missive/queue'
require_relative '../streams/timesheet_stream'
require_relative 'overview_refresher'

class TimesheetsSyncer
  def initialize(qbt, repos, cursor)
    @stream = TimesheetStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @ts_repo = repos.timesheets
  end

  def backfill_all(&done)
    touched = {}
    @stream.each_batch(proc do |rows|
      rows.each do |ts|
        changed = @ts_repo.upsert(ts)
        touched[ts['jobcode_id']] = true if changed
        QuickbooksTime::Missive::Queue.enqueue(QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)) if changed
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
