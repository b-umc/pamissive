# frozen_string_literal: true

class TimesheetsSyncer
  def initialize(qbt, repos, cursor)
    @stream = TimesheetStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @ts_repo = repos.timesheets
  end

  def backfill_all(&done)
    touched = {}
    @stream.each_batch do |rows|
      rows.each do |ts|
        changed = @ts_repo.upsert(ts)
        touched[ts['jobcode_id']] = true if changed
        Missive::Queue.enqueue(Missive::PostBuilder.timesheet_event(ts)) if changed
      end
    end
    OverviewRefresher.rebuild_many(touched.keys) { done&.call(true) }
  rescue StandardError => e
    LOG.error [:timesheet_sync_failed, e.message]
    done&.call(false)
  end
end
