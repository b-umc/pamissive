# frozen_string_literal: true

require 'json'
require_relative '../../../nonblock_socket/select_controller'
require_relative 'client'


class QuickbooksTime
  module Missive
    class Queue
      Task = Struct.new(:action, :payload)

      # Generic FIFO for create/delete operations
      @q = []
      # Coalesced update queues keyed by task id
      @update_queue = []        # Array<String> of task_ids queued for update
      @update_map = {}          # task_id => latest payload (Hash)
      @update_inflight = {}     # task_id => true while an update is in-flight

      @draining = false

      class << self
        include TimeoutInterface

        def enqueue_create_task(payload)
          @q << Task.new(:create_task, payload)
        end

        def enqueue_update_task(task_id, payload)
          return unless task_id
          # Always keep only the most recent payload per task id
          @update_map[task_id.to_s] = payload
          # Enqueue the task id if not already queued or in-flight
          unless @update_inflight[task_id.to_s] || @update_queue.include?(task_id.to_s)
            @update_queue << task_id.to_s
          end
        end

        def enqueue_delete_task(task_id)
          @q << Task.new(:delete_task, task_id) if task_id
        end

        def drain(limiter:, client:, repo: nil)
          return if @draining

          @draining = true
          process_next(limiter, client, repo)
        end

        # Convenience: drain using global Missive limiter and a fresh client.
        def drain_global(repo: nil)
          limiter = QuickbooksTime::Missive::Client.global_limiter || QuickbooksTime::Missive::Client::DEFAULT_LIMITER
          client = QuickbooksTime::Missive::Client.new
          drain(limiter: limiter, client: client, repo: repo)
        end

        private

        def process_next(limiter, client, repo)
          # Prefer coalesced updates to converge quickly
          task_id = next_update_task_id
          if task_id
            payload = @update_map.delete(task_id)
            @update_inflight[task_id] = true
            client.update_task(task_id, payload) do |status, _hdrs, body|
              begin
                if (200..299).include?(status) && repo
                  new_state = body&.dig('tasks', 'state') || payload.dig(:tasks, :state)
                  repo.apply_webhook_task_state(task_id, new_state) if new_state
                end
              rescue StandardError
                # ignore repo errors; continue draining
              ensure
                @update_inflight.delete(task_id)
                # If newer payload arrived while in-flight, ensure it is queued
                if @update_map.key?(task_id) && !@update_queue.include?(task_id)
                  @update_queue << task_id
                end
                add_timeout(proc { process_next(limiter, client, repo) }, 0)
              end
            end
            return
          end

          # Fallback to generic tasks
          task = @q.shift
          unless task
            @draining = false
            return
          end

          case task.action
          when :create_task
            client.create_task(task.payload) do |_status, _hdrs, _body|
              add_timeout(proc { process_next(limiter, client, repo) }, 0)
            end
          when :delete_task
            client.delete_task(task.payload) do |_status, _hdrs, _body|
              add_timeout(proc { process_next(limiter, client, repo) }, 0)
            end
          end
        end

        def next_update_task_id
          # Pop the next task id not currently in-flight
          while (tid = @update_queue.shift)
            return tid unless @update_inflight[tid]
          end
          nil
        end
      end
    end
  end
end
