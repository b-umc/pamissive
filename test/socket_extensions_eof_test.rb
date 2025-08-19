# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require 'timeout'
require_relative '../nonblock_socket/select_controller'
require_relative '../nonblock_socket/TCP/client'
require_relative '../nonblock_socket/TCP/socket_extensions'

class SocketExtensionsEOFTest < Minitest::Test
  def setup
    SelectController.instance.reset
  end

  def test_processes_final_chunk_before_disconnect
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]

    server_thread = Thread.new do
      client = server.accept
      client.write("hi\n")
      client.close
      server.close
    end

    events = []

    handlers = {
      message: MessagePattern.new(proc { |msg, _client| events << [:message, msg] }),
      disconnect: ->(_client) { events << [:disconnect] }
    }

    client = NonBlockSocket::TCP::Client.new('127.0.0.1', port, handlers: handlers)

    select_thread = Thread.new { SelectController.run }

    Timeout.timeout(5) do
      sleep 0.05 until events.any? { |e| e.first == :disconnect }
    end

    select_thread.kill
    server_thread.join

    assert_equal [:message, :disconnect], events.map(&:first)
    assert_equal "hi\n", events.find { |e| e.first == :message }[1]
  end
end
