# frozen_string_literal: true

require_relative '../streams/users_stream'

class UsersSyncer
  def initialize(qbt, repos)
    @stream = UsersStream.new(qbt_client: qbt, limit: Constants::QBT_PAGE_LIMIT)
    @repo = repos.users
  end

  def run(&done)
    @stream.each_batch(proc { |rows| rows.each { |u| @repo.upsert(u) } }) do |ok|
      done&.call(ok)
    end
  rescue StandardError => e
    LOG.error [:users_sync_failed, e.message]
    done&.call(false)
  end
end
