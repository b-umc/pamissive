# frozen_string_literal: true

require_relative '../missive/post_builder'
require_relative '../missive/queue'

class EventHandler
  def initialize(repos)
    @ts_repo = repos.timesheets
  end

  def handle_timesheet_event(ts)
    changed, old_post_id = @ts_repo.upsert(ts)
    if changed
      QuickbooksTime::Missive::Queue.enqueue_delete(old_post_id)
      payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
      Array(payloads).each do |payload|
        QuickbooksTime::Missive::Queue.enqueue_post(payload, timesheet_id: ts['id'])
      end
    end
    changed
  end
end
