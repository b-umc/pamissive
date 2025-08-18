# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'request'
require_relative 'response'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::Session
  attr_reader :port, :client

  def initialize(client)
    client.on(:data, method(:on_data))
    @client = client
    @requests = []
    @handler = nil
    @data_store = {}
  end

  def update_handler(proc)
    @handler = proc
  end

  def []=(key, value)
    @data_store[key] = value
  end

  def [](key)
    @data_store[key]
  end

  def close
    @client.close
  end

  private

  def on_data(data, _)
    req = current_request
    req.parse(data)
    return unless req.completed

    response = NonBlockHTTP::Server::Response.new
    handled = @handler.call(req, response) { |res| client_write(res) }
    client_write(response) unless handled
  end

  def client_write(response)
    @client.on(:emtpy, proc { @client.close }) if response.close?
    @client.write(response.to_s)
  end

  def current_request
    return @requests.last if @requests.last && !@requests.last.completed?

    (@requests << NonBlockHTTP::Server::Request.new(session: self)).last
  end
end
