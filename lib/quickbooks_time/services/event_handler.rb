# frozen_string_literal: true

require_relative '../missive/post_builder'
require_relative '../missive/queue'

class EventHandler
  def initialize(repos)
    @ts_repo = repos.timesheets
  end

  def handle_timesheet_event(ts)
    changed = @ts_repo.upsert(ts)
    QuickbooksTime::Missive::Queue.enqueue(QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)) if changed
    changed
  end
end
