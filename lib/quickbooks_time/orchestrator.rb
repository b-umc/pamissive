class QuickbooksTime
  def authorized
    UsersSyncer.new(qbt, repos).run do |ok|
      return on_fail(:users) unless ok
      JobsSyncer.new(qbt, repos).run do |ok2|
        return on_fail(:jobs) unless ok2
        TimesheetsSyncer.new(qbt, repos, cursor).backfill_all do |ok3|
          return on_fail(:timesheets) unless ok3
          Missive::Dispatcher.start(queue, limiter)   # background drainer
        end
      end
    end
  end
end
