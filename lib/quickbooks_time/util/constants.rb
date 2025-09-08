# frozen_string_literal: true

require 'date'
require 'time'

module Constants
  # Deterministic epoch for all backfills and initial syncs
  BACKFILL_EPOCH_DATE = Date.new(2024, 1, 1)
  QBT_EPOCH_ISO       = Time.utc(2024, 1, 1).iso8601

  QBT_PAGE_LIMIT          = ENV.fetch('QBT_PAGE_LIMIT', '200').to_i
  QBT_RATE_INTERVAL       = ENV.fetch('QBT_RATE_INTERVAL', '0.2').to_f
  # Minimum seconds between Missive API requests. Missive default limit is
  # ~360 req/hour (≈1 every 10s). Use 10s by default, configurable via env.
  MISSIVE_POST_MIN_INTERVAL = ENV.fetch('MISSIVE_POST_MIN_INTERVAL', '10').to_f
  QBT_POLL_INTERVAL       = ENV.fetch('QBT_POLL_INTERVAL', '60').to_i
  # Fast heartbeat to check QBT last_modified_timestamps
  QBT_HEARTBEAT_INTERVAL  = ENV.fetch('QBT_HEARTBEAT_INTERVAL', '3').to_i
  QBT_TODAY_SCAN_INTERVAL = ENV.fetch('QBT_TODAY_SCAN_INTERVAL', '15').to_i
  QBT_SINCE_LOOKBACK_DAYS = ENV.fetch('QBT_SINCE_LOOKBACK_DAYS', '1').to_i
  # Seconds to subtract from the saved cursor when calling modified_since to
  # avoid missing rows that have the same second as the last sync.
  QBT_SINCE_SKEW_SEC      = ENV.fetch('QBT_SINCE_SKEW_SEC', '5').to_i
  # Rolling window (in days) used for start_date alongside modified_since
  # to include older-dated timesheets that were edited recently. Set to a
  # higher value (e.g., 60) for safety, or disable start_date entirely.
  QBT_SINCE_WINDOW_DAYS   = ENV.fetch('QBT_SINCE_WINDOW_DAYS', '60').to_i
  # If set to '1', do not include start_date when using modified_since.
  QBT_DISABLE_START_DATE_WITH_SINCE = ENV.fetch('QBT_DISABLE_START_DATE_WITH_SINCE', '0') == '1'
  MISSIVE_VERIFY_LOOKBACK_MIN = ENV.fetch('MISSIVE_VERIFY_LOOKBACK_MIN', '180').to_i
  MISSIVE_VERIFY_INTERVAL     = ENV.fetch('MISSIVE_VERIFY_INTERVAL', '60').to_i
  MISSIVE_BACKFILL_MONTHS = ENV.fetch('MISSIVE_BACKFILL_MONTHS', '0').to_i
  MISSIVE_WEBHOOK_WAIT_SEC = ENV.fetch('MISSIVE_WEBHOOK_WAIT_SEC', '4').to_i
  QBT_DEFAULT_TZ          = ENV.fetch('QBT_DEFAULT_TZ', 'America/Vancouver')
  MISSIVE_USE_TASKS       = ENV.fetch('MISSIVE_USE_TASKS', '1') == '1'
  MISSIVE_LIVE_UPDATES    = ENV.fetch('MISSIVE_LIVE_UPDATES', '1') == '1'
  MISSIVE_DEFER_DURING_FULL_RESYNC = ENV.fetch('MISSIVE_DEFER_DURING_FULL_RESYNC', '1') == '1'
  MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION = ENV.fetch('MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION', '1') == '1'

  STATUS_COLORS = {
    'unbilled'    => '#2266ED',
    'generated'   => '#6b7280',
    'sent'        => '#5c6ac4',
    'paid'        => '#10b981',
    'overdue'     => '#ef4444',
    'do_not_bill' => '#6b7280',
    'expired'     => '#b7791f',
    'unknown'     => '#9ca3af'
  }.freeze
end
