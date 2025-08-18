# frozen_string_literal: true

class OverviewRefresher
  def self.rebuild_many(job_ids, repo: OverviewRepo.new, &blk)
    job_ids.each { |id| repo.rebuild_overview!(id) }
    blk&.call(true)
  end
end
