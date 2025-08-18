# frozen_string_literal: true

require 'socket'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../select_controller'
require_relative 'socket_extensions'

# A suite of socket libraries built on non-blocking io without threading.
module NonBlockSocket; end

# TCP libs for non-blocking suite
module NonBlockSocket::TCP; end

# TCP Client lib
class NonBlockSocket::TCP::Client
  READ_LENGTH = 2048
  RECONNECT_DELAY_INITIAL = 1   # Initial reconnect delay in seconds
  RECONNECT_DELAY_MAX = 60      # Maximum reconnect delay in seconds

  include SocketInterface
  include TimeoutInterface
  include NonBlockSocket::TCP::SocketExtensions

  attr_reader :host, :port

  def initialize(host, port, handlers: {})
    @socket = nil
    @host = host
    @port = port
    @wait_io = true
    add_handlers(handlers)
    connect_nonblock
  end

  private

  def connect_nonblock
    @socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    @socket.connect_nonblock(Socket.sockaddr_in(@port, @host), exception: false)
    readable?
  rescue Socket::ResolutionError => e
    on_error(e, e.backtrace)
    on_disconnect
  end

  def readable?
    to_io.read_nonblock(1)
    setup_io
  rescue IO::WaitWritable, IO::WaitReadable
    setup_io
  rescue Errno::ECONNREFUSED => e
    on_error(e, e.backtrace)
    on_disconnect
  end

  def setup_io
    remove_readable(to_io)
    @wait_io = false
    connected
  end
end
