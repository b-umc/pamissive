# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../../nonblock_socket/manager'
require_relative 'session'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::Server
  attr_reader :port

  def initialize(tcp_server)
    @tcp = tcp_server
    @port = @tcp.port
    @sessions = {}
    @handlers = {}
    # @auth_exclude = []
    @tcp.add_handlers(connection_handlers)
  end

  def update_auth(prc = nil, &block)
    @auth_hook = prc || block
  end

  def on(path_string, callback = nil, &block)
    prc = callback || block
    @handlers[path_string] = prc
    # @auth_exclude << path_string if auth_exclude
    # @sessions.each { |sess,| sess.on(path_string, prc) }
    LOG.debug([:server_paths_updated, @handlers.keys])
  end

  # def on(path_string, callback = nil, auth_exclude: false, &block)
  #   prc = callback || block
  #   @handlers[path_string] = prc
  #   @auth_exclude << path_string if auth_exclude
  #   # @sessions.each { |sess,| sess.on(path_string, prc) }
  #   LOG.debug([:server_paths_updated, @handlers.keys])
  # end

  def connection_handlers
    {
      connect: method(:client_connected),
      disconnect: method(:client_disconnected)
    }
  end

  private

  def client_disconnected(client)
    @sessions.delete_if { |_, v| v == client }
  end

  def client_connected(client)
    session = NonBlockHTTP::Server::Session.new(client)
    @sessions[session]&.close
    @sessions[session] = client
    session.update_handler(method(:handle_route))
    # @handlers.each { |k, v| session.on(k, v) }
  end

  # def authed(req, res)
  #   return true if @auth_exclude.include?(req.path)

  #   LOG.debug([:path_not_excluded_from_auth, :auth_hook_callable?, @auth_hook.respond_to?(:call)])
  #   @auth_hook.respond_to?(:call) && @auth_hook.call(req, res)
  # end

  # def auth_check(req, res, &block)
  #   LOG.debug([:check_auth_for, req.path])
  #   handle_authed(req, res, &block) if authed(req, res)
  # end

  def handle_route(req, res, &block)
    LOG.debug([:auth_successful])
    handler = @handlers[req.path]
    return not_found(req, res) unless handler.respond_to?(:call)

    handler.call(req, res, &block)
  end

  def unauthorized(request, response)
    LOG.error(['Unauthorized resquest', request.path, 'Returning 401'])
    response.status = 401
    response.close
    false
  end

  def not_found(request, response)
    LOG.error(['no valid response for', request.path, 'Returning 404'])
    response.status = 404
    response.close
    false
  end
end
