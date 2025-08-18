# frozen_string_literal: true

class JobsStream
  def initialize(qbt_client:, limit:)
    @qbt = qbt_client
    @limit = limit
  end

  def each_batch
    page = 1
    loop do
      resp = @qbt.jobcodes(page: page, limit: @limit)
      rows = resp['jobcodes'] || []
      break if rows.empty?
      yield(rows)
      break unless resp['more']
      page += 1
    end
  end
end
