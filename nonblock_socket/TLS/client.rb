# frozen_string_literal: true

require 'socket'
require 'openssl'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../select_controller'
require_relative '../TCP/client'

module NonBlockSocket::TLS; end

class NonBlockSocket::TLS::Client < NonBlockSocket::TCP::Client
  SSL_DELAY = 0.1
  def initialize(host, port, context: nil, handlers: {})
    @context = context || setup_default_context
    super(host, port, handlers: handlers)
  end

  def setup_default_context
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
    ssl_context.cert_store = OpenSSL::X509::Store.new
    ssl_context.cert_store.set_default_paths
    # LOG.debug("SSL Certificate paths loaded: #{ssl_context.cert_store}")
    ssl_context
  end

  def setup_tls
    @ssl_socket = OpenSSL::SSL::SSLSocket.new(@socket, @context)
    @ssl_socket.sync_close = true
    @ssl_socket.hostname = @host
    handle_tls_handshake
  end

  def handle_tls_handshake
    @ssl_socket.connect_nonblock(exception: false)
    @wait_io = false
  rescue Errno::ECONNREFUSED => e
    on_error(e, e.backtrace)
    on_disconnect
  rescue OpenSSL::SSL::SSLErrorWaitReadable
    add_sock(method(:ssl_handshake_readable), to_io)
  rescue OpenSSL::SSL::SSLErrorWaitWritable
    add_writable(method(:ssl_handshake_writable), to_io)
  rescue OpenSSL::SSL::SSLError => e
    LOG.error("SSL Error: #{e.class} - #{e.message}")
    on_error(e, e.backtrace)
    on_disconnect
  end

  def to_io
    @socket
  end

  def to_sock
    @ssl_socket
  end

  private

  def setup_io
    #LOG.debug([:ssl_setup_io, @error_status&.first])
    return schedule_reconnect if @error_status

    super
    @wait_io = true
    setup_tls
  end

  def read_chunk
    super
  rescue OpenSSL::SSL::SSLErrorWaitReadable, OpenSSL::SSL::SSLErrorWaitWritable
    LOG.debug(:ssl_read_delay)
    ssl_delay { read_chunk }
  end

  def write_chunk
    super
  rescue OpenSSL::SSL::SSLErrorWaitReadable, OpenSSL::SSL::SSLErrorWaitWritable
    #LOG.debug(:ssl_write_delay)
    ssl_delay { write_chunk }
  end

  def ssl_delay(&block)
    rb = remove_readable(to_io)
    wb = remove_writable(to_io)
    add_timeout(
      proc do
        add_readable(rb, to_io) if rb
        add_writable(wb, to_io) if wb
        block.call
      end,
      SSL_DELAY
    )
  end

  def ssl_handshake_readable
    handle_tls_handshake
    remove_readable(@ssl_socket.to_io)
  end

  def ssl_handshake_writable
    handle_tls_handshake
    remove_writable(@ssl_socket.to_io)
  end
end
