# frozen_string_literal: true

require 'ostruct'
require 'json'
require 'securerandom'

class QuickbooksTime
  module Missive
    class Client
      API_ENDPOINT = 'https://api.missive.app'

      def post(payload)
        res = OpenStruct.new(code: 200, body: { posts: { id: SecureRandom.uuid } }.to_json)
        yield(res) if block_given?
        res
      end

      def delete(path)
        res = OpenStruct.new(code: 200, body: 'ok')
        yield(res) if block_given?
        res
      end

      def get(path)
        res = OpenStruct.new(code: 200, body: '{}')
        yield(res) if block_given?
        res
      end
    end
  end
end
