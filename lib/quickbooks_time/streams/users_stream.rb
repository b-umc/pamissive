# frozen_string_literal: true

require_relative '../../../logging/app_logger'
require_relative '../../shared/dt'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class UsersStream
  def initialize(qbt_client:, cursor_store:, limit:)
    @qbt = qbt_client
    @cursor = cursor_store
    @limit = limit
  end

  def each_batch(on_rows, &done)
    ts, id = @cursor.read
    fetch_page(ts, id, 1, on_rows, nil, &done)
  end

  private

  def fetch_page(ts, id, page, on_rows, last_row, &done)
    @qbt.users_modified_since(ts, page: page, limit: @limit) do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = resp.dig('results', 'users')&.values || []
      rows.sort_by! do |r|
        lm = Shared::DT.parse_utc(r['last_modified'])
        [lm ? lm.to_i : 0, r['id'].to_i]
      end

      # Filter out rows at/before the cursor using robust UTC comparisons
      before_count = rows.size
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      rejected = before_count - rows.size
      LOG.debug [:users_page, page, :count, rows.size, :rejected, rejected, :more, resp['more']]
      on_rows.call(rows) if rows.any?

      last_row = rows.last || last_row

      if resp['more']
        fetch_page(ts, id, page + 1, on_rows, last_row, &done)
      else
        @cursor.write(last_row['last_modified'], last_row['id']) if last_row
        LOG.debug [:users_sync_complete]
        done&.call(true)
      end
    end
  end

  def before_or_equal_cursor?(row, ts, id)
    rid = row['id']
    lm_t = Shared::DT.parse_utc(row['last_modified'])
    ts_t = Shared::DT.parse_utc(ts)
    return false unless lm_t && ts_t
    (lm_t < ts_t) || (lm_t == ts_t && rid.to_i <= id.to_i)
  end
end
