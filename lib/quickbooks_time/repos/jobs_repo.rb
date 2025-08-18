# frozen_string_literal: true

class JobsRepo
  def initialize
    @data = {}
  end

  def upsert(job)
    id = job['id'] || job[:id]
    changed = @data[id] != job
    @data[id] = job
    changed
  end
end
