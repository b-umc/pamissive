# frozen_string_literal: true

module Missive
  class Queue
    @q = []
    @draining = false

    class << self
      def enqueue(post)
        @q << post
      end

      def drain(limiter:, client:)
        return if @draining
        @draining = true
        while (post = @q.shift)
          limiter.wait_until_allowed { client.post(post) }
        end
        @draining = false
      end
    end
  end
end
