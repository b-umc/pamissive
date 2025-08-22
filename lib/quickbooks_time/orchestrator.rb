require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'services/missive_backfiller'
require_relative 'missive/dispatcher'
require_relative 'util/constants'
require_relative '../../nonblock_socket/select_controller'

class QuickbooksTime
  include TimeoutInterface
  attr_reader :qbt, :repos, :cursor, :users_cursor, :jobs_cursor, :queue, :limiter
  attr_accessor :auth

  POLL_INTERVAL = Constants::QBT_POLL_INTERVAL

  def initialize(qbt:, repos:, cursor:, users_cursor:, jobs_cursor:, queue:, limiter:, auth: nil)
    @qbt = qbt
    @repos = repos
    @cursor = cursor
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
    LOG.info [:quickbooks_time_sync_start]
    UsersSyncer.new(qbt, repos, users_cursor).run do |ok|
      if ok
        JobsSyncer.new(qbt, repos, jobs_cursor).run do |ok2|
          if ok2
            TimesheetsSyncer.new(qbt, repos, cursor).backfill_all do |ok3|
              if ok3
                MissiveBackfiller.new(repos.timesheets, Constants::MISSIVE_BACKFILL_MONTHS).run
                QuickbooksTime::Missive::Dispatcher.start(queue, limiter, repos.timesheets)
                schedule_polls

                LOG.info [:quickbooks_time_sync_complete]
              else
                on_fail(:timesheets)
              end
            end
          else
            on_fail(:jobs)
          end
        end
      else
        on_fail(:users)
      end
    end
  end

  def auth_url
    auth&.auth_url || '#'
  end

  def status
    auth&.status || false
  end

  private

  def on_fail(stage)
    LOG.error [:quickbooks_time_sync_failed, stage]
  end

  def schedule_polls
    add_timeout(proc { poll_users }, POLL_INTERVAL)
    add_timeout(proc { poll_jobs }, POLL_INTERVAL)
    add_timeout(proc { poll_timesheets }, POLL_INTERVAL)
  end

  def poll_users
    UsersSyncer.new(qbt, repos, users_cursor).run do |_ok|
      add_timeout(proc { poll_users }, POLL_INTERVAL)
    end
  end

  def poll_jobs
    JobsSyncer.new(qbt, repos, jobs_cursor).run do |_ok|
      add_timeout(proc { poll_jobs }, POLL_INTERVAL)
    end
  end

  def poll_timesheets
    TimesheetsSyncer.new(qbt, repos, cursor).backfill_all do |_ok|
      QuickbooksTime::Missive::Dispatcher.start(queue, limiter, repos.timesheets)
      add_timeout(proc { poll_timesheets }, POLL_INTERVAL)
    end
  end
end
