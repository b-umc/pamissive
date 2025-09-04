# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class TimesheetStream
  def initialize(qbt_client:, cursor_store:, limit:)
    @qbt = qbt_client
    @cursor = cursor_store
    @limit = limit
  end

  def each_batch(on_rows, &done)
    ts, id = @cursor.read
    begin
      # Guard against a cursor that has drifted into the future which would
      # starve the modified_since polling. If detected, clamp to now-1s.
      t = Time.parse(ts).utc rescue nil
      if t && t > Time.now.utc
        clamped = (Time.now.utc - 1).iso8601
        LOG.warn [:qbt_cursor_in_future_clamped, ts, :clamped_to, clamped]
        ts = clamped
      end
    rescue StandardError
      # ignore parse failures; use raw ts
    end
    fetch_page(ts, id, 1, on_rows, nil, &done)
  end

  private

  def fetch_page(ts, id, page, on_rows, last_row, &done)
    @qbt.timesheets_modified_since(ts, page: page, limit: @limit, supplemental: true) do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = sort_rows(resp)
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      LOG.debug [:timesheets_page, page, :count, rows.size, :more, resp['more']]
      on_rows.call(rows) if rows.any?

      last_row = rows.last || last_row

      if resp['more']
        fetch_page(ts, id, page + 1, on_rows, last_row, &done)
      else
        if last_row
          ts_to_write = last_row['last_modified']
          begin
            # Never persist a last_modified that is in the future; clamp to now-1s
            t = Time.parse(ts_to_write).utc
            if t > Time.now.utc
              clamped = (Time.now.utc - 1)
              LOG.warn [:qbt_last_modified_in_future_clamped, ts_to_write, :clamped_to, clamped.iso8601]
              ts_to_write = clamped.iso8601
            else
              ts_to_write = t.iso8601
            end
          rescue StandardError
            # leave ts_to_write as-is on parse error
          end
          @cursor.write(ts_to_write, last_row['id'])
        end
        LOG.debug [:timesheets_sync_complete]
        done&.call(true)
      end
    end
  end

  def sort_rows(resp)
    rows = resp.dig('results', 'timesheets')&.values || []
    rows.sort_by { |r| [r['last_modified'], r['id']] }
  end

  def before_or_equal_cursor?(row, ts, id)
    lm = row['last_modified']
    rid = row['id']
    lm < ts || (lm == ts && rid.to_i <= id.to_i)
  end
end
