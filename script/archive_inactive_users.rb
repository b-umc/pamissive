# frozen_string_literal: true

# Usage:
#   DRY_RUN=1 ruby script/archive_inactive_users.rb
#   DRY_RUN=0 ruby script/archive_inactive_users.rb
#
# Optional env:
#   QBT_INACTIVE_USERS_LABEL_ID  Missive shared label id to tag archived user convos

require_relative '../env/token_manager'
require_relative '../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../lib/quickbooks_time/repos/timesheets_repo'
require_relative '../lib/quickbooks_time/repos/users_repo'
require_relative '../lib/quickbooks_time/repos/jobs_repo'
require_relative '../lib/quickbooks_time/services/inactive_users_archiver'
require_relative '../nonblock_socket/select_controller'

DRY_RUN = ENV.fetch('DRY_RUN', '1') != '0'

def run
  ts_repo   = TimesheetsRepo.new(db: DB)
  users_repo = UsersRepo.new(db: DB)
  jobs_repo = JobsRepo.new(db: DB)
  repos = OpenStruct.new(timesheets: ts_repo, users: users_repo, jobs: jobs_repo)

  InactiveUsersArchiver.new(repos).run(dry_run: DRY_RUN) do |ok|
    puts(ok ? 'Archived inactive user conversations.' : 'Archiving had errors.')
  end
  SelectController.run
end

run

