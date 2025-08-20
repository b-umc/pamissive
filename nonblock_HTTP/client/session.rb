# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../../nonblock_socket/manager'
require_relative 'request'
require_relative 'response'

class NonBlockHTTP::Client::ClientSession
  def get(url, options = {}, callback = nil, log_debug: false, &block)
    @debug = log_debug
    @dc_called = false
    @callback = callback || block
    build_request(url, options, __callee__)
    @socket.on(:data, method(:handle_data))
    @socket.on(:disconnect, method(:handle_disconnect))
    # LOG.debug([:write_http, @request]) if @debug
    @socket.write(@request.to_s)
  end

  alias post get
  alias put get
  alias delete get
  alias patch get
  alias head get
  alias options get
  alias connect get
  alias trace get

  private

  def build_request(url, request_options = nil, verb = nil)
    @verb ||= verb
    @options ||= request_options
    @request = NonBlockHTTP::Client::Request.new(url, options: @options, verb: @verb)
    @socket = socket
  end

  def socket
    NonBlockSocket::Manager.socket(
      @request.host,
      @request.port,
      use_tls: @request.ssl?,
      ssl_context: @request.ssl_context
    )
  end

  def handle_data(message_data, sock)
    @response ||= NonBlockHTTP::Client::Response.new
    # LOG.debug([:handling_response, @response.completed, @response.close?, message_data])
    @response.parse(message_data)
    return unless @response.completed

    @dc_called = true
    sock.close if @response.close?
    @callback.call(@response)
  end

  def handle_disconnect(_sock)
    return if @dc_called
    # sock.close
    @dc_called = true
    @callback.call(@response)
  end
end
