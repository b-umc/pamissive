# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../../../nonblock_socket/event_bus'

class QuickbooksTime
  class WebhookRecorder
    def initialize(repos:)
      @timesheets = repos.timesheets
      EventBus.subscribe('missive_webhook', 'task_updated', method(:record_task_state))
      LOG.info [:webhook_recorder_initialized]
    end

    def record_task_state(args)
      data = args&.first || {}
      task_id = data[:id]
      state   = data[:state]
      return unless task_id && state

      ok = @timesheets.apply_webhook_task_state(task_id, state)
      LOG.info [:missive_task_state_recorded, task_id, state, :ok, ok]
    rescue => e
      LOG.error [:webhook_recorder_error, e.class, e.message]
    end
  end
end

