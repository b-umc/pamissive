"""
This file is part of the QuickbooksTime Missive integration.
"""

# frozen_string_literal: true

require 'json'
require_relative '../../../api/missive/missive'

class QuickbooksTime
  module Missive
    # Adapter around the top-level `Missive` API helper that adds
    # basic concurrency limiting and 429 retry handling.
    class Client
      include TimeoutInterface

      MAX_CONCURRENCY = 5

      def initialize(channel = ::MISSIVE)
        @channel = channel
        @queue = []
        @active = 0
      end

      def create_task(payload, &blk)
        enqueue(:post, 'tasks', { tasks: payload }, &blk)
      end

      def update_task(task_id, payload, &blk)
        enqueue(:patch, "tasks/#{task_id}", payload, &blk)
      end

      def delete_task(task_id, &blk)
        update_task(task_id, { tasks: { status: 'deleted' } }, &blk)
      end

      private

      def enqueue(verb, path, payload, &blk)
        @queue << [verb, path, payload, blk]
        drain
      end

      def drain
        return if @active >= MAX_CONCURRENCY
        job = @queue.shift
        return unless job
        verb, path, payload, blk = job
        @active += 1
        send_request(verb, path, payload) do |status, headers, body|
          if status == 429
            retry_after = (headers['Retry-After'] || headers['retry-after'] || '1').to_f
            add_timeout(proc { enqueue(verb, path, payload, &blk) }, retry_after)
          else
            blk.call(status, headers, body) if blk
          end
          @active -= 1
          drain
        end
      end

      def send_request(verb, path, payload, &blk)
        case verb
        when :post
          @channel.channel_post(path, payload) do |res|
            blk.call(res.code, res.headers.to_h, parse_body(res.body))
          end
        when :patch
          @channel.channel_patch(path, payload) do |res|
            blk.call(res.code, res.headers.to_h, parse_body(res.body))
          end
        end
      end

      def parse_body(body)
        JSON.parse(body) rescue nil
      end
    end
  end
end

