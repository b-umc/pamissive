# frozen_string_literal: true

# Usage:
#   BACKFILL_START_DATE=2024-01-01 DRY_RUN=0 ruby script/missive_summary_backfill.rb
#   WINDOW_MONTHS=16 ruby script/missive_summary_backfill.rb
#
# Env:
#   BACKFILL_START_DATE  inclusive start date (YYYY-MM-DD). Overrides WINDOW_MONTHS if set
#   WINDOW_MONTHS        months to include counting back from today (default 16)
#   DRY_RUN              1 = don't post, just print (default 0)
#   TYPE                 optional: 'user' or 'job' (default both)

require 'date'
require 'ostruct'

require_relative '../env/token_manager'
require_relative '../lib/quickbooks_time/repos/timesheets_repo'
require_relative '../lib/quickbooks_time/missive/client'
require_relative '../lib/quickbooks_time/services/summary_poster'
require_relative '../lib/quickbooks_time/repos/jobs_repo'
require_relative '../lib/quickbooks_time/repos/users_repo'
require_relative '../lib/quickbooks_time/util/constants'
require_relative '../nonblock_socket/select_controller'
require_relative '../logging/app_logger'

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

WINDOW_MONTHS = (ENV['WINDOW_MONTHS'] || 16).to_i
DRY_RUN       = ENV['DRY_RUN'].to_s == '1'
ONLY_TYPE     = ENV['TYPE']&.to_s&.downcase # 'user' | 'job' | nil

def backfill_start_date
  override = ENV['BACKFILL_START_DATE']
  return Date.parse(override) if override && !override.strip.empty?
  return(Date.today << WINDOW_MONTHS) if WINDOW_MONTHS.positive?
  Constants::BACKFILL_EPOCH_DATE
rescue => e
  LOG.warn([:summary_backfill_start_date_error, e.class, e.message])
  Constants::BACKFILL_EPOCH_DATE
end

def distinct_jobs_since(start_date)
  <<~SQL
    SELECT DISTINCT quickbooks_time_jobsite_id::text AS id
    FROM quickbooks_time_timesheets
    WHERE COALESCE(deleted, false) IS NOT TRUE
      AND quickbooks_time_jobsite_id IS NOT NULL
      AND quickbooks_time_jobsite_id <> 0
      AND date >= '#{start_date}'
    ORDER BY id ASC
  SQL
end

def distinct_users_since(start_date)
  <<~SQL
    SELECT DISTINCT user_id::text AS id
    FROM quickbooks_time_timesheets
    WHERE COALESCE(deleted, false) IS NOT TRUE
      AND date >= '#{start_date}'
    ORDER BY id ASC
  SQL
end

def run
  start_date = backfill_start_date
  puts [:summary_backfill_start, start_date: start_date.to_s, dry_run: DRY_RUN, type: ONLY_TYPE].inspect

  ts_repo = TimesheetsRepo.new(db: DB)
  jobs_repo = JobsRepo.new(db: DB)
  users_repo = UsersRepo.new(db: DB)
  repos = OpenStruct.new(timesheets: ts_repo, jobs: jobs_repo, users: users_repo)
  poster = SummaryPoster.new(repos)

  # Gather unique ids (we post a single all-time summary per entity)
  ids = []
  DB.exec(distinct_users_since(start_date.to_s)) do |res|
    res&.each { |r| ids << [:user, r['id']] }
  end unless ONLY_TYPE && ONLY_TYPE != 'user'

  DB.exec(distinct_jobs_since(start_date.to_s)) do |res|
    res&.each { |r| ids << [:job, r['id']] }
  end unless ONLY_TYPE && ONLY_TYPE != 'job'

  idx = 0
  step = proc do
    if idx >= ids.length
      puts [:summary_backfill_done, count: ids.length].inspect
      return
    end
    type, id = ids[idx]
    idx += 1
    if DRY_RUN
      puts [:would_post_summary_all_time, type, id].inspect
      return add_timeout(step, 0)
    end
    if type == :job
      poster.post_job(job_id: id, date: Date.today) { add_timeout(step, 0) }
    else
      poster.post_user(user_id: id, date: Date.today) { add_timeout(step, 0) }
    end
  end

  step.call
  SelectController.run
end

run
