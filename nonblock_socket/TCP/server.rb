# frozen_string_literal: true

require 'socket'
require 'fcntl'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../select_controller'
require_relative 'socket_extensions'

module NonBlockSocket; end
module NonBlockSocket::TCP; end

class NonBlockSocket::TCP::Server
  include SocketInterface
  include TimeoutInterface
  include Fcntl

  attr_reader :port

  CHUNK_LENGTH = 2048
  TCP_SERVER_FIRST_RETRY_SECONDS = 1
  TCP_SERVER_RETRY_LIMIT_SECONDS = 60
  TCP_SERVER_RETRY_MULTIPLIER = 2

  def initialize(**kwargs)
    @addr = kwargs[:host] || '0.0.0.0'
    @port = kwargs[:port] || 0
    @setup_proc = method(:setup_server)
    @handlers = kwargs[:handlers] || {}
    setup_server
  end

  def add_handlers(handlers)
    handlers.each { |event, proc| on(event, proc) }
  end

  def on(event, proc = nil, &block)
    @handlers[event] = proc || block
  end

  def setup_server
    @server ||= TCPServer.new(@addr, @port)
    @port = @server.addr[1]
    LOG.debug([self, @port])
    add_readable(method(:handle_accept), @server)
    LOG.info("Server setup complete, listening on port #{@port}")
  rescue Errno::EADDRINUSE
    port_in_use
  end

  def handle_accept
    LOG.info([:accepting_non_block_client, @port])
    client = @server.accept_nonblock
    setup_client(client)
  rescue IO::WaitReadable, IO::WaitWritable
    # If the socket isn't ready, ignore for now
  end

  def setup_client(client)
    client.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
    client = NonBlockSocket::TCP::Wrapper.new(client)
    @handlers.each { |k, v| client.on(k, v) }
    client.connected
  end

  def close
    @server.close
  end

  def available?
    !(@server.nil? || @server.closed?)
  end

  private

  def port_in_use
    LOG.error("TCP server could not start on Port #{@port} already in use")
    @server_setup_retry_seconds ||= TCP_SERVER_FIRST_RETRY_SECONDS
    exit if @server_setup_retry_seconds > TCP_SERVER_RETRY_LIMIT_SECONDS
    add_timeout(@setup_proc, @server_setup_retry_seconds * TCP_SERVER_RETRY_MULTIPLIER) unless timeout?(@setup_proc)
  end
end
