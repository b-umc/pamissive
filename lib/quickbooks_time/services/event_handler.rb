# frozen_string_literal: true

require_relative '../missive/post_builder'
require_relative '../missive/queue'
require_relative '../missive/conversation_resolver'

class EventHandler
  def initialize(repos)
    @ts_repo = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
  end

  def handle_timesheet_event(ts)
    changed, old_post_id = @ts_repo.upsert(ts)
    if changed
      QuickbooksTime::Missive::Queue.enqueue_delete(old_post_id)
      job_id  = ts['quickbooks_time_jobsite_id']
      user_id = ts['user_id']
      job_convo = QuickbooksTime::Missive::ConversationResolver.ensure_job(job_id, @jobs_repo)
      user_convo = QuickbooksTime::Missive::ConversationResolver.ensure_user(user_id, @users_repo)
      payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts, job_conversation_id: job_convo, user_conversation_id: user_convo)
      payloads.each { |p| QuickbooksTime::Missive::Queue.enqueue_post(p, timesheet_id: ts['id']) }
    end
    changed
  end
end
