# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require 'timeout'

require_relative '../nonblock_HTTP/client/session'
require_relative '../nonblock_socket/select_controller'

class NonblockHttpClientSessionTest < Minitest::Test
  def setup
    SelectController.instance.reset
  end

  def test_callback_invoked_once_per_response
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]

    server_thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
      client.close
      server.close
    end

    responses = []
    NonBlockHTTP::Client::ClientSession.new.get("http://127.0.0.1:#{port}/") do |resp|
      responses << resp
    end

    select_thread = Thread.new { SelectController.run }

    Timeout.timeout(5) do
      sleep 0.05 until responses.any?
    end

    select_thread.kill
    server_thread.join

    assert_equal 1, responses.size
    refute_nil responses.first
    assert_equal 'hello', responses.first.body
  end
end
