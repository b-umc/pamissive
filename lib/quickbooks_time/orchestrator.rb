require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'missive/dispatcher'

class QuickbooksTime
  attr_reader :qbt, :repos, :cursor, :queue, :limiter

  def initialize(qbt:, repos:, cursor:, queue:, limiter:)
    @qbt = qbt
    @repos = repos
    @cursor = cursor
    @queue = queue
    @limiter = limiter
  end

  def authorized
    UsersSyncer.new(qbt, repos).run do |ok|
      return on_fail(:users) unless ok
      JobsSyncer.new(qbt, repos).run do |ok2|
        return on_fail(:jobs) unless ok2
        TimesheetsSyncer.new(qbt, repos, cursor).backfill_all do |ok3|
          return on_fail(:timesheets) unless ok3
          Missive::Dispatcher.start(queue, limiter)   # background drainer
        end
      end
    end
  end

  def auth_url
    '#'
  end

  def status
    false
  end

  private

  def on_fail(stage)
    LOG.error [:quickbooks_time_sync_failed, stage]
  end
end
