require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'missive/dispatcher'

class QuickbooksTime
  attr_reader :qbt, :repos, :cursor, :queue, :limiter
  attr_accessor :auth

  def initialize(qbt:, repos:, cursor:, queue:, limiter:, auth: nil)
    @qbt = qbt
    @repos = repos
    @cursor = cursor
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
    UsersSyncer.new(qbt, repos).run do |ok|
      if ok
        JobsSyncer.new(qbt, repos).run do |ok2|
          if ok2
            TimesheetsSyncer.new(qbt, repos, cursor).backfill_all do |ok3|
              if ok3
                QuickbooksTime::Missive::Dispatcher.start(queue, limiter)   # background drainer
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
end
