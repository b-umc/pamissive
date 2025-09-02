# frozen_string_literal: true

require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'services/timesheets_today_scanner'
require_relative 'services/timesheets_for_missive_creator'
require_relative 'services/missive_task_verifier'
require_relative 'missive/client'
require_relative 'util/constants'
require_relative '../../nonblock_socket/select_controller'

class QuickbooksTime
  include TimeoutInterface
  attr_reader :qbt, :repos, :timesheets_cursor, :users_cursor, :jobs_cursor, :queue, :limiter
  attr_accessor :auth

  POLL_METHODS = [
    :poll_users,
    :poll_jobs,
    :poll_timesheets,
    :poll_timesheets_today,
    :process_timesheets_for_missive_tasks,
    :reconcile_missive_task_states,
    :verify_missive_tasks,
    :drain_missive_queue
  ]

  POLL_INTERVAL = Constants::QBT_POLL_INTERVAL

  def initialize(qbt:, repos:, timesheets_cursor:, users_cursor:, jobs_cursor:, queue:, limiter:, auth: nil)
    @qbt = qbt
    @repos = repos
    @timesheets_cursor = timesheets_cursor
    @users_cursor = users_cursor
    @jobs_cursor = jobs_cursor
    @queue = queue
    @limiter = limiter
    @auth = auth
    @polling_started = false
    @auth_ready = !!auth&.status
    @html_ready = false
  end

  def auth=(auth)
    @auth = auth
    @auth_ready = !!auth&.status
    LOG.debug [:qbt_auth_ready, @auth_ready]
    try_start_polling
  end

  # Backward-compatibility: some callers may still invoke `authorized`.
  # We interpret that as the HTML/UI layer being ready to start polling.
  def authorized
    html_authorized!
  end

  # Explicitly signal that the HTML/session layer has been authorized and is ready.
  def html_authorized!
    @html_ready = true
    LOG.debug [:qbt_html_ready, @html_ready]
    try_start_polling
  end

  def auth_url
    auth&.auth_url || '#'
  end

  def status
    auth&.status || false
  end

  private

  def on_fail(stage)
    LOG.error [:quickbooks_time_poll_failed, stage]
  end

  def try_start_polling
    return if @polling_started
    unless @auth_ready && @html_ready
      unless @auth_ready
        LOG.info [:qbt_polling_waiting, :reason, :auth_token_missing]
      end
      unless @html_ready
        LOG.info [:qbt_polling_waiting, :reason, :html_not_authorized]
      end
      return
    end

    @polling_started = true
    LOG.info [:quickbooks_time_authorized_starting_poll_cycle]
    schedule_polls
  rescue => e
    LOG.error [:qbt_polling_start_error, e.class, e.message]
  end

  def schedule_polls
    stagger = POLL_INTERVAL / POLL_METHODS.size
    POLL_METHODS.each_with_index do |method_name, index|
      add_timeout(proc { send(method_name) }, stagger * (index + 1))
    end
  end

  def poll_users
    UsersSyncer.new(qbt, repos, users_cursor).run do |ok|
      on_fail(:users) unless ok
      add_timeout(method(:poll_users), POLL_INTERVAL)
    end
  end

  def poll_jobs
    JobsSyncer.new(qbt, repos, jobs_cursor).run do |ok|
      on_fail(:jobs) unless ok
      add_timeout(method(:poll_jobs), POLL_INTERVAL)
    end
  end

  def poll_timesheets
    TimesheetsSyncer.new(qbt, repos, timesheets_cursor).backfill_all do |ok|
      on_fail(:timesheets) unless ok
      add_timeout(method(:poll_timesheets), POLL_INTERVAL)
    end
  end

  # Faster cycle specifically for detecting in-progress timesheets today.
  def poll_timesheets_today
    TimesheetsTodayScanner.new(qbt, repos).run do |ok|
      on_fail(:timesheets_today) unless ok
      add_timeout(method(:poll_timesheets_today), Constants::QBT_TODAY_SCAN_INTERVAL)
    end
  end

  def process_timesheets_for_missive_tasks
    TimesheetsForMissiveCreator.new(repos).run do
      add_timeout(method(:process_timesheets_for_missive_tasks), POLL_INTERVAL)
    end
  end

  def reconcile_missive_task_states
    QuickbooksTime::TaskStateReconciler.new(repos).run do
      add_timeout(method(:reconcile_missive_task_states), POLL_INTERVAL)
    end
  end

  def verify_missive_tasks
    QuickbooksTime::MissiveTaskVerifier.new(repos).run do
      add_timeout(method(:verify_missive_tasks), Constants::MISSIVE_VERIFY_INTERVAL)
    end
  end

  def drain_missive_queue
    # Kick the Missive queue; it no-ops if already draining
    QuickbooksTime::Missive::Queue.drain(limiter: limiter, client: QuickbooksTime::Missive::Client.new, repo: repos.timesheets)
    add_timeout(method(:drain_missive_queue), POLL_INTERVAL)
  end
end
