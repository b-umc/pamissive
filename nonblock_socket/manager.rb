# frozen_string_literal: true

require_relative '../logging/app_logger'
LOG = AppLogger.setup(__FILE__) unless defined?(LOG)
require_relative 'TLS/client'
require_relative 'TLS/server'

class NonBlockSocket::Manager
  def self.socket(host, port, use_tls: false, ssl_context: nil)
    @sockets ||= {}
    key = server_key(host: host, port: port, use_tls: use_tls)
    socket = @sockets[key]
    return socket unless socket.nil? || socket.closed?

    @sockets[key] = create_socket(host, port, use_tls, ssl_context)
  end

  def self.server(**kwargs)
    @servers ||= {}
    server = @servers[server_key(**kwargs)]
    return server if server&.available?

    ser = create_server(**kwargs)
    @servers[server_key(ser.port, **kwargs)] = ser
  end

  def self.create_socket(host, port, use_tls, ssl_context)
    return NonBlockSocket::TCP::Client.new(host, port) unless use_tls

    NonBlockSocket::TLS::Client.new(host, port, context: ssl_context)
  end

  def self.create_server(**kwargs)
    return NonBlockSocket::TCP::Server.new(**kwargs) unless kwargs[:use_tls]

    NonBlockSocket::TLS::Server.new(**kwargs)
  end

  def self.server_key(port = nil, **kwargs)
    "#{kwargs[:host]}:#{port || kwargs[:port]}:#{kwargs[:use_tls]}"
  end
end
