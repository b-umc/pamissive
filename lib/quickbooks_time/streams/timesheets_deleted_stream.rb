# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../../shared/dt'

class TimesheetsDeletedStream
  def initialize(qbt_client:, cursor_store:, limit:)
    @qbt = qbt_client
    @cursor = cursor_store
    @limit = limit
  end

  def each_batch(on_rows, &done)
    ts, id = @cursor.read
    # Normalize DB cursor timestamp to UTC ISO
    begin
      t_norm = Shared::DT.parse_utc(ts, source: :db_input_time)
      if t_norm
        LOG.debug [:db_input_time, ts, :to, :internal_time, t_norm.iso8601]
        ts = t_norm.iso8601
      end
    rescue StandardError
      # ignore parse failures
    end
    fetch_page(ts, id, 1, on_rows, nil, &done)
  end

  private

  def fetch_page(ts, id, page, on_rows, last_row, &done)
    @qbt.timesheets_deleted_modified_since(ts, page: page, limit: @limit) do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = extract_rows(resp)
      rows.sort_by! do |r|
        lm = Shared::DT.parse_utc(deleted_ts(r))
        [lm ? lm.to_i : 0, r['id'].to_i]
      end
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      LOG.debug [:timesheets_deleted_page, page, :count, rows.size, :more, resp['more']]
      on_rows.call(rows) if rows.any?

      last_row = rows.last || last_row

      if resp['more']
        fetch_page(ts, id, page + 1, on_rows, last_row, &done)
      else
        if last_row
          lm = Shared::DT.parse_utc(deleted_ts(last_row))
          if lm
            LOG.debug [:internal_output_time, lm.iso8601, :to, :db_output_time, lm.iso8601]
            @cursor.write(lm.iso8601, last_row['id'])
          else
            @cursor.write(deleted_ts(last_row), last_row['id'])
          end
        end
        LOG.debug [:timesheets_deleted_sync_complete]
        done&.call(true)
      end
    end
  end

  def extract_rows(resp)
    # Support either { results: { timesheets_deleted: {...} } } or direct array
    rows_hash = resp.dig('results', 'timesheets_deleted') || resp.dig('timesheets_deleted') || {}
    if rows_hash.is_a?(Hash)
      rows = rows_hash.values
    else
      rows = rows_hash || []
    end
    rows
  end

  def deleted_ts(row)
    row['last_modified'] || row['deleted'] || row['deleted_at'] || row['modified'] || ''
  end

  def before_or_equal_cursor?(row, ts, id)
    rid = row['id']
    lm_t = Shared::DT.parse_utc(deleted_ts(row))
    ts_t = Shared::DT.parse_utc(ts)
    return false unless lm_t && ts_t
    (lm_t < ts_t) || (lm_t == ts_t && rid.to_i <= id.to_i)
  end
end
