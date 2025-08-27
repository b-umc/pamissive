# frozen_string_literal: true

require 'json'
require_relative '../../../api/missive/missive'
require_relative '../../../nonblock_HTTP/client/session'
require_relative '../../../nonblock_socket/select_controller'

class QuickbooksTime
  module Missive
    class HttpClient
      include TimeoutInterface

      MAX_CONCURRENCY = 5

      def initialize
        @queue = []
        @active = 0
      end

      def post(path, json:, &blk)
        enqueue(:post, path, json, &blk)
      end

      def patch(path, json:, &blk)
        enqueue(:patch, path, json, &blk)
      end

      private

      def enqueue(verb, path, json, &blk)
        @queue << [verb, path, json, blk]
        drain
      end

      def drain
        return if @active >= MAX_CONCURRENCY
        job = @queue.shift
        return unless job
        verb, path, json, blk = job
        @active += 1
        send_request(verb, path, json) do |status, headers, body|
          if status == 429
            retry_after = (headers['retry-after'] || headers['Retry-After'] || '1').to_f
            add_timeout(proc { enqueue(verb, path, json, &blk) }, retry_after)
          else
            blk.call(status, headers, body) if blk
          end
          @active -= 1
          drain
        end
      end

      def send_request(verb, path, json, &blk)
        url = path.start_with?('http') ? path : "#{::Missive::API_URL}#{path}"
        NonBlockHTTP::Client::ClientSession.new.send(verb, url, { headers: ::Missive::HEADERS, body: json.to_json }) do |res|
          status = res.code
          headers = res.headers.to_h
          body = JSON.parse(res.body) rescue nil
          blk.call(status, headers, body)
        end
      end
    end
  end
end
