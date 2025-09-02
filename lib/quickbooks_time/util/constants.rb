# frozen_string_literal: true

module Constants
  QBT_PAGE_LIMIT          = ENV.fetch('QBT_PAGE_LIMIT', '200').to_i
  QBT_RATE_INTERVAL       = ENV.fetch('QBT_RATE_INTERVAL', '0.2').to_f
  MISSIVE_POST_MIN_INTERVAL = ENV.fetch('MISSIVE_POST_MIN_INTERVAL', '5').to_f
  QBT_POLL_INTERVAL       = ENV.fetch('QBT_POLL_INTERVAL', '60').to_i
  QBT_TODAY_SCAN_INTERVAL = ENV.fetch('QBT_TODAY_SCAN_INTERVAL', '15').to_i
  QBT_SINCE_LOOKBACK_DAYS = ENV.fetch('QBT_SINCE_LOOKBACK_DAYS', '1').to_i
  MISSIVE_VERIFY_LOOKBACK_MIN = ENV.fetch('MISSIVE_VERIFY_LOOKBACK_MIN', '180').to_i
  MISSIVE_VERIFY_INTERVAL     = ENV.fetch('MISSIVE_VERIFY_INTERVAL', '60').to_i
  MISSIVE_BACKFILL_MONTHS = ENV.fetch('MISSIVE_BACKFILL_MONTHS', '0').to_i
  MISSIVE_WEBHOOK_WAIT_SEC = ENV.fetch('MISSIVE_WEBHOOK_WAIT_SEC', '4').to_i
  QBT_DEFAULT_TZ          = ENV.fetch('QBT_DEFAULT_TZ', 'America/Vancouver')

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
