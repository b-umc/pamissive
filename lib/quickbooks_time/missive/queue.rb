# frozen_string_literal: true

require 'json'
require_relative '../../../nonblock_socket/select_controller'

class QuickbooksTime
  module Missive
    class Queue
      Task = Struct.new(:action, :payload, :timesheet_id)

      @q = []
      @draining = false

      class << self
        include TimeoutInterface

        def enqueue_post(payload, timesheet_id: nil)
          @q << Task.new(:post, payload, timesheet_id)
        end

        def enqueue_delete(post_id)
          @q << Task.new(:delete, post_id, nil) if post_id
        end

        def drain(limiter:, client:, repo:)
          return if @draining

          @draining = true
          process_next(limiter, client, repo)
        end

        private

        def process_next(limiter, client, repo)
          task = @q.shift
          unless task
            @draining = false
            return
          end

          limiter.wait_until_allowed do
            case task.action
            when :post
              client.post(task.payload) do |res|
                if task.timesheet_id && (200..299).include?(res.code)
                  begin
                    body = JSON.parse(res.body)
                    post_id = body.dig('posts', 'id')
                    repo.save_post_id(task.timesheet_id, post_id) if post_id
                  rescue JSON::ParserError
                    # ignore
                  end
                end
                add_timeout(proc { process_next(limiter, client, repo) }, 0)
              end
            when :delete
              client.delete("posts/#{task.payload}") do |_res|
                add_timeout(proc { process_next(limiter, client, repo) }, 0)
              end
            end
          end
        end
      end
    end
  end
end
