# frozen_string_literal: true

require_relative '../missive/task_builder'
require_relative '../missive/task_sync'
require_relative '../missive/http_client'
require_relative '../util/constants'
require_relative '../../../logging/app_logger'

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class TimesheetsForMissiveCreator
  def initialize(repos)
    @repos = repos
    client = QuickbooksTime::Missive::HttpClient.new
    @task_sync = QuickbooksTime::Missive::TaskSync.new(client: client)
  end

  def run(&callback)
    start_date = if Constants::MISSIVE_BACKFILL_MONTHS.positive?
                   Date.today << Constants::MISSIVE_BACKFILL_MONTHS
                 end

    timesheets_to_process = @repos.timesheets.tasks_to_create_or_update(start_date)

    process_next = proc do
      if timesheets_to_process.empty?
        callback&.call
      else
        ts = timesheets_to_process.shift
        process_one_timesheet(ts) { process_next.call }
      end
    end

    process_next.call
  end

  private

  def process_one_timesheet(ts, &callback)
    start_t, end_t = QuickbooksTime::Missive::TaskBuilder.compute_times(ts)
    title = QuickbooksTime::Missive::TaskBuilder.build_task_title(ts)
    desc  = QuickbooksTime::Missive::TaskBuilder.build_task_description(ts, start_t, end_t)

    @task_sync.sync_pair!(
      ts: ts,
      user_conv_id: ts['user_conversation_id'],
      job_conv_id:  ts['jobsite_conversation_id'],
      titles:       { user: title, jobsite: title },
      descriptions: { user: desc, jobsite: desc }
    ) do |tasks|
      @repos.timesheets.set_user_task!(ts['id'], tasks[:user]['id'], tasks[:user]['state']) if tasks[:user]
      @repos.timesheets.set_job_task!(ts['id'], tasks[:job]['id'], tasks[:job]['state']) if tasks[:job]
      callback.call
    end
  end
end
