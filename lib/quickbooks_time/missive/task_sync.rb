# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class QuickbooksTime
  module Missive
    class TaskSync
      def initialize(client:)
        @client = client
      end

      def desired_state(on_the_clock)
        return 'in_progress' if on_the_clock
        'closed'
      end

      def create_and_ensure!(payload, desired, ts_id, &done)
        LOG.debug([:missive_create_payload, ts_id, payload])
        @client.create_task(payload) do |status, hdrs, json|
          LOG.debug([:missive_create_response, ts_id, :status, status, :headers, hdrs, :body, json])
          task = (200..299).include?(status) ? json&.dig('tasks') : nil
          return done.call(nil) unless task
          return done.call(task) if task['state'] == desired
          LOG.debug([:task_state, ts_id, :from, task['state'], :to, desired])
          @client.update_task(task['id'], { tasks: { state: desired } }) do |s2, h2, j2|
            LOG.debug([:missive_update_response, ts_id, :status, s2, :headers, h2, :body, j2])
            done.call(j2&.dig('tasks'))
          end
        end
      end

      def sync_pair!(ts:, titles:, descriptions:, &done)
        desired = desired_state(ts[:on_the_clock] || ts['on_the_clock'])

        user_payload = {
          title: titles[:user], description: descriptions[:user].to_s,
          subtask: true, state: desired
        }
        job_payload  = {
          title: titles[:jobsite], description: descriptions[:jobsite].to_s,
          subtask: true, state: desired
        }

        results = { user: nil, job: nil }
        left = 2
        join = proc { left -= 1; done.call(results) if left.zero? }

        create_and_ensure!(user_payload, desired, ts[:id]) { |t| results[:user] = t; join.call }
        create_and_ensure!(job_payload,  desired, ts[:id]) { |t| results[:job]  = t; join.call }
      end
    end
  end
end
