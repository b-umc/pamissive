# frozen_string_literal: true

class TimesheetsRepo
  def initialize
    @data = {}
  end

  def upsert(ts)
    id = ts['id'] || ts[:id]
    changed = @data[id] != ts
    @data[id] = ts
    changed
  end
end
