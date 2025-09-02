# frozen_string_literal: true

require_relative '../../../logging/app_logger'
require_relative '../../../nonblock_socket/event_bus'
require_relative '../util/constants'
require_relative '../../../nonblock_socket/select_controller'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class QuickbooksTime
  module Missive
    class TaskSync
      include TimeoutInterface
      def initialize(client:)
        @client = client
      end

      def desired_state(ts)
        on_the_clock = ts[:on_the_clock] || ts['on_the_clock']
        # Default closed unless explicitly on the clock
        return 'closed' unless on_the_clock

        # If it's marked on_the_clock but appears stale (>12h), treat as closed
        begin
          start_t, end_t = QuickbooksTime::Missive::TaskBuilder.compute_times(ts)
          reference_time = end_t || start_t
          if reference_time && (Time.now - reference_time) > (12 * 60 * 60)
            return 'closed'
          end
        rescue StandardError
          # If compute fails, fall through and consider on_the_clock
        end

        'in_progress'
      end

      def create_and_ensure!(payload, desired, ts_id, &done)
        LOG.debug([:missive_create_payload, ts_id, payload])
        @client.create_task(payload) do |status, hdrs, json|
          LOG.debug([:missive_create_response, ts_id, :status, status, :headers, hdrs, :body, json])
          task = (200..299).include?(status) ? json&.dig('tasks') : nil
          return done.call(nil) unless task

          # If already matches, finish.
          return done.call(task) if task['state'] == desired

          # Wait briefly for webhook to confirm state change from Missive rules.
          task_id = task['id']
          LOG.debug([:task_state, ts_id, :from, task['state'], :to, desired])

          received = false
          handler = proc do |args|
            data = args&.first || {}
            next unless data[:id] == task_id
            received = true
            EventBus.unsubscribe('missive_webhook', 'task_updated', handler)
            # Do not correct immediately; record and allow poll loop to reconcile
            done.call({ 'id' => task_id, 'state' => data[:state], 'conversation' => data[:conversation] })
          end

          EventBus.subscribe('missive_webhook', 'task_updated', handler)

          # Do not correct immediately; rely on webhook + poll reconciliation
          add_timeout(proc do
            EventBus.unsubscribe('missive_webhook', 'task_updated', handler) unless received
            done.call(task)
          end, Constants::MISSIVE_WEBHOOK_WAIT_SEC)
        end
      end

      def sync_pair!(ts:, user_payload:, job_payload:, &done)
        desired = desired_state(ts)

        user_payload = user_payload.merge(state: desired)
        job_payload  = job_payload.merge(state: desired)

        results = { user: nil, job: nil }
        left = 2
        join = proc { left -= 1; done.call(results) if left.zero? }

        create_and_ensure!(user_payload, desired, ts[:id]) { |t| results[:user] = t; join.call }
        create_and_ensure!(job_payload,  desired, ts[:id]) { |t| results[:job]  = t; join.call }
      end
    end
  end
end
