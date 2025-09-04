# frozen_string_literal: true

# Usage:
#   WINDOW_MONTHS=16 BATCH=200 DRY_RUN=0 ruby script/missive_timesheets_backfill.rb
#
# Env:
#   WINDOW_MONTHS  months to include (default 16)
#   BATCH          rows per pass (default 200)
#   DRY_RUN        1 = don't enqueue, just list (default 0)

require 'date'
require 'time'

# your app bits (adjust paths if needed)
require_relative '../env/token_manager'
require_relative '../lib/quickbooks_time/repos/timesheets_repo'
require_relative '../lib/quickbooks_time/missive/queue' # rescue nil
require_relative '../lib/quickbooks_time/missive/task_builder' # rescue nil
require_relative '../lib/quickbooks_time/util/constants'
# App deps (adjust paths if needed)
# frozen_string_literal: true

# Env:
#   WINDOW_MONTHS  months to include (default 16)
#   BATCH          rows per page (default 200)
#   DRY_RUN        1 = print only, don't enqueue

WINDOW_MONTHS = (ENV['WINDOW_MONTHS'] || 16).to_i
BATCH         = [(ENV['BATCH'] || 200).to_i, 200].min
DRY_RUN       = ENV['DRY_RUN'].to_s == '1'

def backfill_start_date
  # Prefer explicit override, else use our deterministic epoch from constants.
  override = ENV['BACKFILL_START_DATE']
  return override if override && !override.strip.empty?

  Constants::BACKFILL_EPOCH_DATE.strftime('%Y-%m-%d')
rescue => e
  LOG.warn([:backfill_start_date_error, e.class, e.message])
  Constants::BACKFILL_EPOCH_DATE.strftime('%Y-%m-%d')
end

def enqueue_row(ts)
  if DRY_RUN
    LOG.debug([:would_enqueue, ts['id'] || ts[:id], ts['date'] || ts[:date]])
    return
  end
  Missive::Queue.enqueue_timesheet(ts)
rescue => e
  LOG.warn([:enqueue_row_error, (ts['id'] || ts[:id]), e.class, e.message])
end

def page_sql
  <<~SQL
    SELECT *
    FROM quickbooks_time_timesheets
    WHERE (missive_jobsite_task_id IS NULL OR missive_user_task_id IS NULL)
      AND date >= $1
    ORDER BY date ASC, id ASC
    LIMIT $2 OFFSET $3
  SQL
end

def backfill_page_async(start_date:, limit:, offset:, totals:)
  params = [start_date, limit, offset]
  LOG.debug([:db_query, start_date: start_date, limit: limit, offset: offset, dry_run: DRY_RUN])

  DB.exec_params(page_sql, params) do |result|
		puts page_sql, params
		p result
    # Handle nil/error result gracefully
    unless result
      LOG.warn([:db_query_nil_result, offset])
      return
    end

    count = result.ntuples
    if count.zero?
      LOG.debug([:db_backfill_done, seen: totals[:seen], enqueued: totals[:enq]])
      next
    end

    totals[:seen] += count
    # Iterate rows; PG::Result#each yields hashes with string keys
    result.each do |row|
      enqueue_row(row)
      totals[:enq] += 1 unless DRY_RUN
    end

    # Chain next page
    backfill_page_async(start_date: start_date, limit: limit, offset: offset + limit, totals: totals)
  end
rescue => e
  LOG.warn([:backfill_page_async_error, e.class, e.message])
end

def start_async_backfill
  sdate  = backfill_start_date
  totals = { seen: 0, enq: 0 }
  LOG.debug([:db_backfill_start, start_date: sdate, batch: BATCH, dry_run: DRY_RUN])
  backfill_page_async(start_date: sdate, limit: BATCH, offset: 0, totals: totals)
rescue => e
  LOG.warn([:start_async_backfill_error, e.class, e.message])
end

# Kick off from your reactor init
start_async_backfill
SelectController.run
