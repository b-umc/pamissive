# frozen_string_literal: true

require_relative 'client'

class QuickbooksTime
  module Missive
    class Dispatcher
      def self.start(queue, limiter)
        client = QuickbooksTime::Missive::Client.new
        queue.drain(limiter: limiter, client: client)
      end
    end
  end
end
