# frozen_string_literal: true

class SyncLogRepo
  def log(event, status)
    # store sync log entries
    (@logs ||= []) << { event: event, status: status, at: Time.now }
  end
end
