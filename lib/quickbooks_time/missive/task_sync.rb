# frozen_string_literal: true

require_relative '../../../logging/app_logger'
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
        # Use the same logic as the rest of the system to avoid drift with
        # reconciliation and verification.
        QuickbooksTime::Missive::TaskBuilder.determine_task_state(ts)
      end

      def create_and_ensure!(payload, desired, ts_id, &done)
        LOG.debug([:missive_create_payload, ts_id, payload])
        @client.create_task(payload) do |status, hdrs, json|
          LOG.debug([:missive_create_response, ts_id, :status, status, :headers, hdrs, :body, json])
          task = (200..299).include?(status) ? json&.dig('tasks') : nil
          return done.call(nil) unless task

          # If already matches, finish.
          return done.call(task) if task['state'] == desired

          # Webhooks are unreliable; fetch recent conversation comments to see
          # if Missive rules already adjusted the task state.
          conv_id = task['conversation']
          task_id = task['id']
          LOG.debug([:task_state_check, ts_id, :task_id, task_id, :conv, conv_id, :from, task['state'], :to, desired])

          if conv_id && task_id
            @client.get_conversation_comments(conv_id, limit: 10) do |st2, _hdr2, body2|
              if (200..299).include?(st2) && body2.is_a?(Hash)
                comments = body2['comments'] || []
                found = comments.find { |c| c['task'] && (c['task']['id'] == task_id) && c['task']['state'] }
                if found
                  task['state'] = found['task']['state']
                end
              end
              done.call(task)
            end
          else
            done.call(task)
          end
        end
      end

      def sync_pair!(ts:, user_payload:, job_payload:, &done)
        desired = desired_state(ts)

        user_payload = user_payload&.merge(state: desired)
        job_payload  = job_payload&.merge(state: desired)

        results = { user: nil, job: nil }
        # Determine how many creations we need to wait for
        left = 0
        left += 1 if user_payload
        left += 1 if job_payload
        # If nothing to do, return immediately
        return done.call(results) if left.zero?
        join = proc { left -= 1; done.call(results) if left.zero? }

        if user_payload
          create_and_ensure!(user_payload, desired, ts[:id]) { |t| results[:user] = t; join.call }
        end
        if job_payload
          create_and_ensure!(job_payload,  desired, ts[:id]) { |t| results[:job]  = t; join.call }
        end
      end
    end
  end
end
