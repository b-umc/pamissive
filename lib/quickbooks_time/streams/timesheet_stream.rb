# frozen_string_literal: true

class TimesheetStream
  def initialize(qbt_client:, cursor_store:, limit:)
    @qbt = qbt_client
    @cursor = cursor_store
    @limit = limit
  end

  def each_batch(on_rows, &done)
    ts, id = @cursor.read
    fetch_batch(ts, id, on_rows, &done)
  end

  private

  def fetch_batch(ts, id, on_rows, &done)
    @qbt.timesheets_modified_since(ts, after_id: id, limit: @limit, order: :asc, supplemental: true) do |resp|
      return done&.call(false) unless resp

      rows = sort_rows(resp)
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      on_rows.call(rows) if rows.any?

      if resp['more'] && rows.any?
        last = rows.last
        @cursor.write(last['last_modified'], last['id'])
        ts_new, id_new = @cursor.read
        fetch_batch(ts_new, id_new, on_rows, &done)
      else
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
