# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../missive/client'
require_relative '../util/constants'
require_relative 'summary_poster'

class SummariesRefresher
  def initialize(repos)
    @repos = repos
    @poster = SummaryPoster.new(repos)
  end

  # Rebuild single-summary posts for all users and jobs present in DB.
  # Missive requires notifications on all posts; include them.
  def rebuild_all(&done)
    users = @repos.timesheets.distinct_user_ids
    jobs  = @repos.timesheets.distinct_job_ids
    work  = users.map { |u| [:user, u] } + jobs.map { |j| [:job, j] }

    process = proc do
      pair = work.shift
      unless pair
        done&.call(true)
        next
      end
      type, id = pair
      if type == :user
        @poster.post_user(user_id: id, date: Date.today) { process.call }
      else
        @poster.post_job(job_id: id, date: Date.today) { process.call }
      end
    end

    process.call
  rescue => e
    LOG.error [:summaries_rebuild_failed, e.class, e.message]
    done&.call(false)
  end
end
