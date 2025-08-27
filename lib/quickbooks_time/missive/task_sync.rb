# frozen_string_literal: true

require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

module QuickbooksTime
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
        @client.post('/v1/tasks', json: { tasks: payload }) do |status, _hdrs, json|
          task = (200..299).include?(status) ? json&.dig('tasks') : nil
          return done.call(nil) unless task
          return done.call(task) if task['state'] == desired
          LOG.debug([:task_state, ts_id, :from, task['state'], :to, desired])
          @client.patch("/v1/tasks/#{task['id']}", json: { tasks: { state: desired } }) do |_s2, _h2, j2|
            done.call(j2&.dig('tasks'))
          end
        end
      end

      def sync_pair!(ts:, user_conv_id:, job_conv_id:, titles:, descriptions:, &done)
        desired = desired_state(ts[:on_the_clock] || ts['on_the_clock'])

        user_payload = {
          title: titles[:user], description: descriptions[:user].to_s,
          conversation: user_conv_id, subtask: true, state: desired
        }
        job_payload  = {
          title: titles[:jobsite], description: descriptions[:jobsite].to_s,
          conversation: job_conv_id, subtask: true, state: desired
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
