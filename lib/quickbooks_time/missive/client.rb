# frozen_string_literal: true

require 'ostruct'

class QuickbooksTime
  module Missive
    class Client
      API_ENDPOINT = 'https://api.missive.app'

      def post(payload)
        yield(OpenStruct.new(code: 200, body: 'ok')) if block_given?
      end

      def delete(path)
        yield(OpenStruct.new(code: 200, body: 'ok')) if block_given?
      end

      def get(path)
        yield(OpenStruct.new(code: 200, body: '{}')) if block_given?
      end
    end
  end
end
