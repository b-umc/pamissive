# frozen_string_literal: true

require 'json'

class QuickbooksTime
  module Missive
    class Queue
      Task = Struct.new(:action, :payload, :timesheet_id)

      @q = []
      @draining = false

      class << self
        def enqueue_post(payload, timesheet_id: nil)
          @q << Task.new(:post, payload, timesheet_id)
        end

        def enqueue_delete(post_id)
          @q << Task.new(:delete, post_id, nil) if post_id
        end

        def drain(limiter:, client:, repo:)
          return if @draining
          @draining = true
          while (task = @q.shift)
            case task.action
            when :post
              limiter.wait_until_allowed do
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
                end
              end
            when :delete
              limiter.wait_until_allowed { client.delete("posts/#{task.payload}") }
            end
          end
          @draining = false
        end
      end
    end
  end
end
