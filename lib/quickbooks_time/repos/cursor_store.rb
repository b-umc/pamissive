# frozen_string_literal: true

require 'time'

class CursorStore
  def initialize(db:, api_name:, full_resync: false)
    @db = db
    @api_name = api_name

    if full_resync
      @timestamp = Time.at(0).utc.iso8601
      @id = 0
      return
    end

    row = @db.exec_params(
      'SELECT last_successful_sync, last_id FROM api_sync_logs WHERE api_name=$1',
      [@api_name]
    ).first

    @timestamp =
      if row && row['last_successful_sync']
        Time.parse(row['last_successful_sync']).utc.iso8601
      else
        Time.at(0).utc.iso8601
      end

    @id = row && row['last_id'] ? row['last_id'].to_i : 0
  end

  def read
    [@timestamp, @id]
  end

  def write(ts, id)
    @timestamp = ts
    @id = id
    @db.exec_params(
      'INSERT INTO api_sync_logs (api_name, last_successful_sync, last_id) '
      'VALUES ($1,$2,$3) '
      'ON CONFLICT (api_name) DO UPDATE SET '
      '  last_successful_sync=EXCLUDED.last_successful_sync, '
      '  last_id=EXCLUDED.last_id',
      [@api_name, ts, id]
    )
  end
end
