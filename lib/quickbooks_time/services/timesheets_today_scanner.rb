# frozen_string_literal: true

require 'date'
require 'tzinfo'
require_relative '../missive/task_builder'
require_relative '../missive/queue'
require_relative '../util/constants'
require_relative '../../../logging/app_logger'

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

# Polls only today's timesheets to quickly detect in-progress entries.
class TimesheetsTodayScanner
  def initialize(qbt, repos)
    @qbt = qbt
    @ts_repo = repos.timesheets
    @jobs_repo = repos.jobs
    @users_repo = repos.users
  end

  def run(&done)
    # Compute 'today' in the configured default timezone to avoid UTC skew.
    tz = TZInfo::Timezone.get(Constants::QBT_DEFAULT_TZ) rescue TZInfo::Timezone.get('UTC')
    today = tz.to_local(Time.now).to_date
    page = 1
    touched = {}

    handle_page = proc do |resp|
      unless resp
        done&.call(false)
        next
      end

      rows = resp.dig('results', 'timesheets')&.values || []
      rows.sort_by! { |ts| QuickbooksTime::Missive::TaskBuilder.compute_times(ts).last || Time.at(0) }

      rows.each do |ts|
        changed, old_task_ids = @ts_repo.upsert(ts)
        next unless changed

        touched[ts['jobcode_id']] = true

        if Constants::MISSIVE_USE_TASKS && old_task_ids && !old_task_ids.empty?
          ts['user_name'] ||= @users_repo.name(ts['user_id'])
          ts['jobsite_name'] ||= @jobs_repo.name(ts['jobcode_id'])
          update_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
          QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:user_task_id], update_payload)
          QuickbooksTime::Missive::Queue.enqueue_update_task(old_task_ids[:jobsite_task_id], update_payload)
        end
      end

      # Kick the Missive queue after enqueuing updates on this page
      QuickbooksTime::Missive::Queue.drain_global(repo: @ts_repo) if Constants::MISSIVE_USE_TASKS

      if resp['more']
        page += 1
        @qbt.timesheets_by_date(start_date: today.to_s, end_date: today.to_s, page: page, limit: Constants::QBT_PAGE_LIMIT, supplemental: true, &handle_page)
      else
        done&.call(true)
      end
    end

    @qbt.timesheets_by_date(start_date: today.to_s, end_date: today.to_s, page: page, limit: Constants::QBT_PAGE_LIMIT, supplemental: true, &handle_page)
  rescue => e
    LOG.error [:timesheets_today_scan_failed, e.class, e.message]
    done&.call(false)
  end
end
