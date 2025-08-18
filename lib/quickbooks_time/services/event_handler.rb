# frozen_string_literal: true

class EventHandler
  def initialize(repos)
    @ts_repo = repos.timesheets
  end

  def handle_timesheet_event(ts)
    changed = @ts_repo.upsert(ts)
    Missive::Queue.enqueue(Missive::PostBuilder.timesheet_event(ts)) if changed
    changed
  end
end
