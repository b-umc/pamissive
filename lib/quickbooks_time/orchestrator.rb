# frozen_string_literal: true

require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'services/timesheets_for_missive_creator'
require_relative 'util/constants'
require_relative '../../nonblock_socket/select_controller'

class QuickbooksTime
  include TimeoutInterface
  attr_reader :qbt, :repos, :timesheets_cursor, :users_cursor, :jobs_cursor, :queue, :limiter
  attr_accessor :auth

  POLL_METHODS = [
    :poll_users,
    :poll_jobs,
    :poll_timesheets #,
    #:process_timesheets_for_missive_tasks
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
  end

  def auth=(auth)
    @auth = auth
    authorized if auth&.status
  end

  def authorized
    LOG.info [:quickbooks_time_authorized_starting_poll_cycle]
    schedule_polls
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

  def process_timesheets_for_missive_tasks
    TimesheetsForMissiveCreator.new(repos).run do
      add_timeout(method(:process_timesheets_for_missive_tasks), POLL_INTERVAL)
    end
  end
end
