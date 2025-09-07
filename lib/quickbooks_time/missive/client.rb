"""
This file is part of the QuickbooksTime Missive integration.
"""

# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../../../api/missive/missive'
require_relative '../util/constants'
require_relative '../rate_limiter'

class QuickbooksTime
  module Missive
    # Adapter around the top-level `Missive` API helper that adds
    # basic concurrency limiting and 429 retry handling.
      class Client
        include TimeoutInterface

        MAX_CONCURRENCY = 5
        DEFAULT_LIMITER  = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)

        class << self
          attr_accessor :global_limiter
        end

        def initialize(channel = ::MISSIVE, limiter: nil)
          @channel = channel
          @limiter = limiter || self.class.global_limiter || DEFAULT_LIMITER
          @queue = []
          @active = 0
        end

      def create_task(payload, &blk)
        enqueue(:post, 'tasks', { tasks: payload }, &blk)
      end

      def update_task(task_id, payload, &blk)
        # Missive PATCH updates accept the task attributes with an id field.
        # Build a canonical body regardless of how callers shaped the payload.
        attrs = (payload[:tasks] || payload['tasks'] || payload || {}).dup
        #attrs[:id] ||= attrs['id'] || task_id
        body = { tasks: attrs }
        enqueue(:patch, "tasks/#{task_id}", body, &blk)
      end

      def delete_task(task_id, &blk)
        update_task(task_id, { tasks: { status: 'deleted' } }, &blk)
      end

      def get_task(task_id, &blk)
        # Missive Public API does not expose GET /tasks/:id; use filter by ids
        enqueue(:get, "tasks?ids=#{task_id}", nil, &blk)
      end

      def get_conversation_comments(conversation_id, limit: 10, until_ts: nil, &blk)
        qs = ["limit=#{limit}"]
        qs << "until=#{until_ts}" if until_ts
        enqueue(:get, "conversations/#{conversation_id}/comments?#{qs.join('&')}", nil, &blk)
      end

      # --- posts (for summaries, etc.) -------------------------------------

      def create_post(payload, &blk)
        # payload should be a Hash of post attributes (not wrapped)
        enqueue(:post, 'posts', { posts: payload }, &blk)
      end

      def delete_post(post_id, &blk)
        enqueue(:delete, "posts/#{post_id}", nil, &blk)
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
        # Schedule through limiter to respect Missive rate policy globally
        @limiter.wait_until_allowed do
          @active += 1
          send_request(verb, path, payload) do |status, headers, body|
            if status == 429
              ra = headers['Retry-After'] || headers['retry-after'] || headers['retry_after'] || '1'
              ra = ra.first if ra.is_a?(Array)
              retry_after = begin
                Float(ra)
              rescue
                begin
                  t = Time.parse(ra.to_s); [t - Time.now, 1].max
                rescue
                  1.0
                end
              end

              reset_raw = headers['X-RateLimit-Reset'] || headers['x-ratelimit-reset']
              reset_raw = reset_raw.first if reset_raw.is_a?(Array)
              reset_delay = begin
                [Float(reset_raw) - Time.now.to_i, 0].max
              rescue
                0
              end

              backoff = [retry_after, reset_delay].max + 0.5
              add_timeout(proc { enqueue(verb, path, payload, &blk) }, backoff)
            else
              blk.call(status, headers, body) if blk
            end
            @active -= 1
            drain
          end
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
        when :get
          @channel.channel_get(path) do |res|
            blk.call(res.code, res.headers.to_h, parse_body(res.body))
          end
        when :delete
          @channel.channel_delete(path) do |res|
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
