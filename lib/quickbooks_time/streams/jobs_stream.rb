# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

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
      LOG.debug [:jobs_page, page, :count, rows.size, :more, resp['more']]
      on_rows.call(rows) unless rows.empty?

      if resp['more']
        each_batch(on_rows, page + 1, &done)
      else
        LOG.debug [:jobs_sync_complete]
        done&.call(true)
      end
    end
  end
end
