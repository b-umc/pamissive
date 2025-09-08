# frozen_string_literal: true

# Usage:
#   DRY_RUN=1 ruby script/missive_tasks_cleanup.rb
#   START_DATE=2024-01-01 ruby script/missive_tasks_cleanup.rb

require_relative '../env/token_manager'
require_relative '../lib/quickbooks_time/missive/client'
require_relative '../lib/quickbooks_time/util/constants'
require_relative '../lib/quickbooks_time/rate_limiter'
require_relative '../nonblock_socket/select_controller'
require_relative '../logging/app_logger'

LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

DRY_RUN    = ENV['DRY_RUN'].to_s == '1'
START_DATE = ENV['START_DATE']

def tasks_sql
  where = [
    '(missive_user_task_id IS NOT NULL OR missive_jobsite_task_id IS NOT NULL)'
  ]
  where << "date >= '#{START_DATE}'" if START_DATE && !START_DATE.strip.empty?
  <<~SQL
    SELECT DISTINCT COALESCE(missive_user_task_id, missive_jobsite_task_id) AS task_id
    FROM quickbooks_time_timesheets
    WHERE #{where.join(' AND ')}
    ORDER BY task_id ASC
  SQL
end

client = QuickbooksTime::Missive::Client.new
limiter = QuickbooksTime::Missive::Client::DEFAULT_LIMITER

task_ids = []
DB.exec(tasks_sql) { |res| res&.each { |r| task_ids << r['task_id'] } }
task_ids.uniq!

puts [:tasks_cleanup_start, count: task_ids.length, dry_run: DRY_RUN].inspect

idx = 0
step = proc do
  if idx >= task_ids.length
    puts [:tasks_cleanup_done, deleted: (DRY_RUN ? 0 : task_ids.length)].inspect
    return
  end
  tid = task_ids[idx]
  idx += 1
  if DRY_RUN
    puts [:would_delete_task, tid].inspect
    return add_timeout(step, 0)
  end
  client.delete_task(tid) { add_timeout(step, 0) }
end

step.call
SelectController.run

