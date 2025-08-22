# frozen_string_literal: true

require_relative '../missive/post_builder'
require_relative '../missive/queue'

class EventHandler
  def initialize(repos)
    @ts_repo   = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
  end

  def handle_timesheet_event(ts)
    changed, old_post_id = @ts_repo.upsert(ts)
    if changed
      QuickbooksTime::Missive::Queue.enqueue_delete(old_post_id)
      enrich_names(ts)
      payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
      Array(payloads).each do |payload|
        QuickbooksTime::Missive::Queue.enqueue_post(payload, timesheet_id: ts['id'])
      end
    end
    changed
  end

  private

  def enrich_names(ts)
    ts['jobsite_name'] ||= @jobs_repo.name(ts['jobcode_id'] || ts['quickbooks_time_jobsite_id'])
    ts['user_name']    ||= @users_repo.name(ts['user_id'])
  end
end
