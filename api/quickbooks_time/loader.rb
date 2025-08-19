# frozen_string_literal: true

require 'ostruct'

require_relative '../../lib/quickbooks_time/orchestrator'
require_relative '../../lib/quickbooks_time/qbt_client'
require_relative '../../lib/quickbooks_time/repos/users_repo'
require_relative '../../lib/quickbooks_time/repos/jobs_repo'
require_relative '../../lib/quickbooks_time/repos/timesheets_repo'
require_relative '../../lib/quickbooks_time/repos/overview_repo'
require_relative '../../lib/quickbooks_time/repos/sync_log_repo'
require_relative '../../lib/quickbooks_time/repos/cursor_store'
require_relative '../../lib/quickbooks_time/missive/queue'
require_relative '../../lib/quickbooks_time/rate_limiter'
require_relative '../../lib/quickbooks_time/util/constants'
require_relative '../../nonblock_HTTP/manager'
require_relative 'auth_server'


qbt    = QbtClient.new
repos  = OpenStruct.new(
  users:      UsersRepo.new,
  jobs:       JobsRepo.new,
  timesheets: TimesheetsRepo.new,
  overview:   OverviewRepo.new,
  sync_log:   SyncLogRepo.new
)
cursor  = CursorStore.new
queue   = QuickbooksTime::Missive::Queue
limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)

QBT = QuickbooksTime.new(
  qbt: qbt,
  repos: repos,
  cursor: cursor,
  queue: queue,
  limiter: limiter


server = NonBlockHTTP::Manager.server(port: 8080)
auth   = QuickbooksTime::AuthServer.new(server, proc { |*| QBT.authorized })
QBT.auth = auth