# frozen_string_literal: true

require_relative '../streams/jobs_stream'

class JobsSyncer
  def initialize(qbt, repos, cursor)
    @stream = JobsStream.new(qbt_client: qbt, cursor_store: cursor, limit: Constants::QBT_PAGE_LIMIT)
    @repo = repos.jobs
  end

  def run(&done)
    @stream.each_batch(proc { |rows| rows.each { |j| @repo.upsert(j) } }) do |ok|
      done&.call(ok)
    end
  rescue StandardError => e
    LOG.error [:jobs_sync_failed, e.message]
    done&.call(false)
  end
end
