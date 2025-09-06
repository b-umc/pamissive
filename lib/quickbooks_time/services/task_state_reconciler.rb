# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../missive/task_builder'
require_relative '../missive/queue'

class QuickbooksTime
  class TaskStateReconciler
    def initialize(repos)
      @repos = repos
    end

    def run(&done)
      rows = @repos.timesheets.tasks_to_reconcile_state
      LOG.debug [:task_state_reconcile_scan, :count, rows.length]
      rows.each do |ts|
        desired_state = QuickbooksTime::Missive::TaskBuilder.determine_task_state(ts)
        LOG.debug [:reconcile_row, ts['id'], :user_state, ts['missive_user_task_state'], :job_state, ts['missive_jobsite_task_state'], :desired, desired_state]
        # If both recorded states already match the desired state, skip.
        if ts['missive_user_task_state'] == desired_state && ts['missive_jobsite_task_state'] == desired_state
          next
        end
        desired_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)
        user_id = ts['missive_user_task_id']
        job_id  = ts['missive_jobsite_task_id']
        if user_id
          QuickbooksTime::Missive::Queue.enqueue_update_task(user_id, desired_payload)
        end
        if job_id
          QuickbooksTime::Missive::Queue.enqueue_update_task(job_id, desired_payload)
        end
        LOG.info [:reconcile_task_state_enqueued, ts['id'], :desired, desired_payload.dig(:tasks, :state), :user_task, user_id, :job_task, job_id]
      end
      # Kick the Missive queue to process updates immediately (rate-limited)
      QuickbooksTime::Missive::Queue.drain_global(repo: @repos.timesheets)
      done&.call(true)
    rescue => e
      LOG.error [:task_state_reconcile_error, e.class, e.message]
      done&.call(false)
    end
  end
end
