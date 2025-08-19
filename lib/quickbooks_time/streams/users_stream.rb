# frozen_string_literal: true

class UsersStream
  def initialize(qbt_client:, limit:)
    @qbt = qbt_client
    @limit = limit
  end

  def each_batch(on_rows, page = 1, &done)
    @qbt.users(page: page, limit: @limit) do |resp|
      return done&.call(false) unless resp

      rows = resp['users'] || []
      on_rows.call(rows) unless rows.empty?

      if resp['more'] && rows.any?
        each_batch(on_rows, page + 1, &done)
      else
        done&.call(true)
      end
    end
  end
end
