# frozen_string_literal: true

module Constants
  QBT_PAGE_LIMIT          = ENV.fetch('QBT_PAGE_LIMIT', '50').to_i
  QBT_RATE_INTERVAL       = ENV.fetch('QBT_RATE_INTERVAL', '0.2').to_f
  MISSIVE_POST_MIN_INTERVAL = ENV.fetch('MISSIVE_POST_MIN_INTERVAL', '0.4').to_f

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
