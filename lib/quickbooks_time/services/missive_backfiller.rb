# frozen_string_literal: true

require 'date'
require_relative '../missive/post_builder'
require_relative '../missive/queue'
require_relative '../missive/conversation_resolver'

class MissiveBackfiller
  def initialize(repos, months)
    @ts_repo = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
    @months = months.to_i
  end

  def run
    return if @months <= 0

    since = Date.today << @months
    rows  = @ts_repo.unposted_since(since)
    rows.sort_by! { |ts| QuickbooksTime::Missive::PostBuilder.compute_times(ts).last || Time.at(0) }
    rows.each do |ts|
      job_convo = QuickbooksTime::Missive::ConversationResolver.ensure_job(ts['quickbooks_time_jobsite_id'], @jobs_repo)
      user_convo = QuickbooksTime::Missive::ConversationResolver.ensure_user(ts['user_id'], @users_repo)
      payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts, job_conversation_id: job_convo, user_conversation_id: user_convo)
      payloads.each { |p| QuickbooksTime::Missive::Queue.enqueue_post(p, timesheet_id: ts['id']) }
    end
  end
end
