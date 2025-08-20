# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../nonblock_socket/TCP/socket_extensions'

class SocketExtensionsEBADFTest < Minitest::Test
  class FakeSock
    def read_nonblock(_len, exception: false)
      "hi\n"
    end

    def eof?
      raise Errno::EBADF
    end
  end

  class Dummy
    include NonBlockSocket::TCP::SocketExtensions::SocketIO

    attr_reader :events

    def initialize(sock)
      @sock = sock
      @events = []
    end

    def to_sock
      @sock
    end

    def handle_data(dat)
      @events << [:data, dat]
    end

    def on_disconnect(dat = nil)
      @events << [:disconnect, dat]
    end

    # stubs to satisfy interface
    def add_writable(*); end
    def remove_writable(*); end
    def to_io
      @sock
    end
    def remove_readable(*); end
    def close; end
  end

  def test_handles_ebadf_from_eof
    dummy = Dummy.new(FakeSock.new)
    dummy.send(:read_chunk)
    assert_equal [[:data, "hi\n"], [:disconnect, nil]], dummy.events
  end
end
