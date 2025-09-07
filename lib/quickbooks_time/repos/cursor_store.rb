# frozen_string_literal: true

require 'time'
require_relative '../util/constants'
require_relative '../../shared/dt'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class CursorStore
  def initialize(db:, api_name:, full_resync: false)
    @db = db
    @api_name = api_name

    if full_resync
      @timestamp = Constants::QBT_EPOCH_ISO
      @id = 0
      return
    end

    row = @db.exec_params(
      'SELECT last_successful_sync, last_id FROM api_sync_logs WHERE api_name=$1',
      [@api_name]
    ).first

    @timestamp =
      if row && row['last_successful_sync']
        t = Shared::DT.parse_utc(row['last_successful_sync'], source: :db_input_time)
        t ? t.iso8601 : Constants::QBT_EPOCH_ISO
      else
        Constants::QBT_EPOCH_ISO
      end

    @id = row && row['last_id'] ? row['last_id'].to_i : 0
  end

  def read
    [@timestamp, @id]
  end

  def write(ts, id)
    # Normalize and clamp to avoid cursors drifting into the future
    parsed = Shared::DT.parse_utc(ts, source: :cursor_write_input)
    now_utc = Time.now.utc
    ts_to_write = if parsed
      if parsed > now_utc
        clamped = (now_utc - 1)
        LOG.warn [:cursor_write_future_clamped, @api_name, parsed.iso8601, :clamped_to, clamped.iso8601]
        clamped.iso8601
      else
        parsed.iso8601
      end
    else
      ts
    end

    @timestamp = ts_to_write
    @id = id
    LOG.debug [:cursor_store_write, @api_name, :in, ts, :parsed, (parsed&.iso8601), :store, ts_to_write, :id, id]
    sql = <<~SQL
      INSERT INTO api_sync_logs (api_name, last_successful_sync, last_id)
      VALUES ($1,$2,$3)
      ON CONFLICT (api_name) DO UPDATE SET
        last_successful_sync=EXCLUDED.last_successful_sync,
        last_id=EXCLUDED.last_id
    SQL

    @db.exec_params(sql, [@api_name, ts_to_write, id])
  end
end
