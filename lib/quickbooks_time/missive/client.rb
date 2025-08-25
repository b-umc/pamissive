# frozen_string_literal: true

require_relative '../../../api/missive/missive'


class QuickbooksTime
  module Missive
    # Lightweight adapter around the top-level `Missive` API helper
    # that dispatches HTTP requests to the real Missive service.
    class Client
      def initialize(channel = ::MISSIVE)
        @channel = channel
      end

      def create_task(payload, &block)
        @channel.channel_post('tasks', payload, &block)
      end

      def update_task(task_id, payload, &block)
        @channel.channel_patch("tasks/#{task_id}", payload, &block)
      end

      def delete_task(task_id, &block)
        # Tasks are "deleted" by updating their status
        update_task(task_id, { tasks: { status: 'deleted' } }, &block)
      end
    end
  end
end
