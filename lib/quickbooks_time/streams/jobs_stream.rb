# frozen_string_literal: true

class JobsStream
  def initialize(qbt_client:, limit:)
    @qbt = qbt_client
    @limit = limit
  end

  def each_batch(on_rows, page = 1, &done)
    @qbt.jobcodes(page: page, limit: @limit) do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = resp.dig('results', 'jobcodes')&.values || []
      on_rows.call(rows) unless rows.empty?

      if resp['more']
        each_batch(on_rows, page + 1, &done)
      else
        done&.call(true)
      end
    end
  end
end
