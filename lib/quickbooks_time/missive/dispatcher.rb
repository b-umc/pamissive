# frozen_string_literal: true

module Missive
  class Dispatcher
    def self.start(queue, limiter)
      client = Missive::Client.new
      queue.drain(limiter: limiter, client: client)
    end
  end
end
