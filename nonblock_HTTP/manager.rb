# frozen_string_literal: true

require_relative '../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'server/websocket_session'
require_relative 'client/session'
require_relative 'server/server'

module NonBlockHTTP; end

class NonBlockHTTP::Manager
  def self.server(port: 8080, host: '0.0.0.0', use_tls: false)
    tcp = NonBlockSocket::Manager.server(port: port, host: host, use_tls: use_tls)
    @servers ||= {}
    key = server_key(tcp.port, host: host, use_tls: use_tls)
    server = @servers[key]
    return server if server

    ser = NonBlockHTTP::Server::Server.new(tcp)
    @servers[key] = ser
  end

  def self.create_server(**kwargs)
    return NonBlockHTTP::Server.new(**kwargs) unless kwargs[:use_tls]

    NonBlockSocket::TLS::Server.new(**kwargs)
  end

  def self.server_key(port = nil, **kwargs)
    "#{kwargs[:host]}:#{port || kwargs[:port]}:#{kwargs[:use_tls]}"
  end
end
