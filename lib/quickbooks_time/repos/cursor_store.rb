# frozen_string_literal: true

require 'time'

class CursorStore
  def initialize
    @timestamp = Time.at(0).utc.iso8601
    @id = 0
  end

  def read
    [@timestamp, @id]
  end

  def write(ts, id)
    @timestamp = ts
    @id = id
  end
end
