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

      # Send a POST request to the Missive API.
      #
      # `payload` is expected to be a hash shaped according to
      # Missive's API requirements, e.g. `{ posts: { ... } }`.
      def post(payload, &block)
        @channel.channel_post('posts', payload, &block)
      end

      # Forward delete requests to the Missive API. `path` should be a
      # relative endpoint such as "posts/<id>".
      def delete(path, &block)
        @channel.channel_delete(path, &block)
      end

      # Fetch data from the Missive API at the given `path`.
      def get(path, &block)
        @channel.channel_get(path, &block)
      end
    end
  end
end
