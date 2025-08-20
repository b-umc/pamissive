# frozen_string_literal: true

class TimesheetStream
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
    @qbt.timesheets_modified_since(ts, page: page, limit: @limit, supplemental: true) do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = sort_rows(resp)
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      on_rows.call(rows) if rows.any?

      last_row = rows.last || last_row

      if resp['more']
        fetch_page(ts, id, page + 1, on_rows, last_row, &done)
      else
        if last_row
          @cursor.write(last_row['last_modified'], last_row['id'])
        end
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
