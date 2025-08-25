# frozen_string_literal: true

require 'json'
require_relative '../../../nonblock_socket/select_controller'


class QuickbooksTime
  module Missive
    class Queue
      Task = Struct.new(:action, :payload)

      @q = []
      @draining = false

      class << self
        include TimeoutInterface

        def enqueue_create_task(payload)
          @q << Task.new(:create_task, payload)
        end

        def enqueue_update_task(task_id, payload)
          @q << Task.new(:update_task, { task_id: task_id, payload: payload }) if task_id
        end

        def enqueue_delete_task(task_id)
          @q << Task.new(:delete_task, task_id) if task_id
        end

        def drain(limiter:, client:)
          return if @draining

          @draining = true
          process_next(limiter, client)
        end

        private

        def process_next(limiter, client)
          task = @q.shift
          unless task
            @draining = false
            return
          end

          limiter.wait_until_allowed do
            case task.action
            when :create_task
              client.create_task(task.payload) do |_res|
                add_timeout(proc { process_next(limiter, client) }, 0)
              end
            when :update_task
              client.update_task(task.payload[:task_id], task.payload[:payload]) do |_res|
                add_timeout(proc { process_next(limiter, client) }, 0)
              end
            when :delete_task
              client.delete_task(task.payload) do |_res|
                add_timeout(proc { process_next(limiter, client) }, 0)
              end
            end
          end
        end
      end
    end
  end
end
