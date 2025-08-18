# frozen_string_literal: true

class TimesheetStream
  def initialize(qbt_client:, cursor_store:, limit:)
    @qbt = qbt_client
    @cursor = cursor_store
    @limit = limit
  end

  def each_batch
    loop do
      ts, id = @cursor.read
      resp = @qbt.timesheets_modified_since(ts, after_id: id, limit: @limit, order: :asc, supplemental: true)
      rows = sort_rows(resp)
      rows.reject! { |r| before_or_equal_cursor?(r, ts, id) }
      yield(rows)
      break unless resp['more'] && rows.any?
      last = rows.last
      @cursor.write(last['last_modified'], last['id'])
    end
  end

  private

  def sort_rows(resp)
    rows = resp['timesheets'] || []
    rows.sort_by { |r| [r['last_modified'], r['id']] }
  end

  def before_or_equal_cursor?(row, ts, id)
    lm = row['last_modified']
    rid = row['id']
    lm < ts || (lm == ts && rid.to_i <= id.to_i)
  end
end
