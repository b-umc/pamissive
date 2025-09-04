# frozen_string_literal: true

require 'ostruct'
require 'pg'

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
require_relative '../../lib/quickbooks_time/db/schema'
require_relative '../../nonblock_HTTP/manager'
require_relative 'auth_server'
require_relative '../../lib/quickbooks_time/services/task_state_reconciler'

server = NonBlockHTTP::Manager.server(port: 8080)

db_conn = PG.connect(
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
)

rebuild_timesheets = ENV['QBT_REBUILD_TIMESHEETS'] == '1'
QuickbooksTime::DB::Schema.ensure!(db_conn, rebuild_timesheets: rebuild_timesheets)

qbt_limiter     = RateLimiter.new(interval: Constants::QBT_RATE_INTERVAL)
qbt             = QbtClient.new(-> { QBT.auth&.token&.access_token }, limiter: qbt_limiter)
repos           = OpenStruct.new(
  users:      UsersRepo.new(db: db_conn),
  jobs:       JobsRepo.new(db: db_conn),
  timesheets: TimesheetsRepo.new(db: db_conn),
  overview:   OverviewRepo.new,
  sync_log:   SyncLogRepo.new,
)
full_resync = ENV['QBT_FULL_RESYNC'] == '1' || rebuild_timesheets
ts_cursor   = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_timesheets', full_resync: full_resync)
user_cursor = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_users', full_resync: full_resync)
job_cursor  = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_jobs', full_resync: full_resync)
queue           = QuickbooksTime::Missive::Queue
missive_limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)
QuickbooksTime::Missive::Client.global_limiter = missive_limiter

QBT = QuickbooksTime.new(
  qbt: qbt,
  repos: repos,
  timesheets_cursor: ts_cursor,
  users_cursor: user_cursor,
  jobs_cursor: job_cursor,
  queue: queue,
  limiter: missive_limiter
) unless defined?(QBT)
auth = QuickbooksTime::AuthServer.new(server, proc { |srv| QBT.auth = srv })
QBT.auth ||= auth

# Missive webhooks are disabled; rely on verification + reconciliation.

at_exit { db_conn.close }

# # frozen_string_literal: true

# require 'ostruct'
# require 'pg'

# require_relative '../../lib/quickbooks_time/orchestrator'
# require_relative '../../lib/quickbooks_time/qbt_client'
# require_relative '../../lib/quickbooks_time/repos/users_repo'
# require_relative '../../lib/quickbooks_time/repos/jobs_repo'
# require_relative '../../lib/quickbooks_time/repos/timesheets_repo'
# require_relative '../../lib/quickbooks_time/repos/overview_repo'
# require_relative '../../lib/quickbooks_time/repos/sync_log_repo'
# require_relative '../../lib/quickbooks_time/repos/cursor_store'
# require_relative '../../lib/quickbooks_time/missive/queue'
# require_relative '../../lib/quickbooks_time/rate_limiter'
# require_relative '../../lib/quickbooks_time/util/constants'
# require_relative '../../lib/quickbooks_time/db/schema'
# require_relative '../../nonblock_HTTP/manager'
# require_relative 'auth_server'

# server = NonBlockHTTP::Manager.server(port: 8080)

# db_conn = PG.connect(
#   dbname: 'ruby_jobsites',
#   user: ENV.fetch('PG_JOBSITES_UN', nil),
#   password: ENV.fetch('PG_JOBSITES_PW', nil),
#   host: 'localhost'
# )

# rebuild_timesheets = ENV['QBT_REBUILD_TIMESHEETS'] == '1'
# QuickbooksTime::DB::Schema.ensure!(db_conn, rebuild_timesheets: rebuild_timesheets)

# qbt_limiter     = RateLimiter.new(interval: Constants::QBT_RATE_INTERVAL)
# qbt             = QbtClient.new(-> { QBT.auth&.token&.access_token }, limiter: qbt_limiter)
# repos           = OpenStruct.new(
#   users:      UsersRepo.new(db: db_conn),
#   jobs:       JobsRepo.new(db: db_conn),
#   timesheets: TimesheetsRepo.new(db: db_conn),
#   overview:   OverviewRepo.new,
#   sync_log:   SyncLogRepo.new,
# )
# full_resync = ENV['QBT_FULL_RESYNC'] == '1' || rebuild_timesheets
# timesheets_cursor   = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_timesheets', full_resync: full_resync)
# user_cursor = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_users', full_resync: full_resync)
# job_cursor  = CursorStore.new(db: db_conn, api_name: 'quickbooks_time_jobs', full_resync: full_resync)
# queue           = QuickbooksTime::Missive::Queue
# missive_limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)

# QBT = QuickbooksTime.new(
#   qbt: qbt,
#   repos: repos,
#   timesheets_cursor: ts_cursor,
#   users_cursor: user_cursor,
#   jobs_cursor: job_cursor,
#   queue: queue,
#   limiter: missive_limiter
# ) unless defined?(QBT)
# auth = QuickbooksTime::AuthServer.new(server, proc { |srv| QBT.auth = srv })
# QBT.auth ||= auth

# at_exit { db_conn.close }
