# frozen_string_literal: true

require_relative '../streams/jobs_stream'

class JobsSyncer
  def initialize(qbt, repos)
    @stream = JobsStream.new(qbt_client: qbt, limit: Constants::QBT_PAGE_LIMIT)
    @repo = repos.jobs
  end

  def run(&done)
    @stream.each_batch do |rows|
      rows.each { |j| @repo.upsert(j) }
    end
    done&.call(true)
  rescue StandardError => e
    LOG.error [:jobs_sync_failed, e.message]
    done&.call(false)
  end
end
