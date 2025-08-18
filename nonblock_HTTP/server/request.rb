# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'request_handler'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::Request
  attr_reader :body, :headers, :completed, :session, :raw

  def initialize(data = nil, session: {})
    @raw = data || ''.dup
    @session = session
    @headers = NonBlockHTTP::Server::RequestHandler.new
    @body = ''.dup
    parse(data)
  end

  def parse(new_data)
    return if new_data.to_s.empty?

    @raw << new_data
    @body << @headers.parse(new_data).to_s
    @completed = true if @headers.completed && @body.size == @headers.length?.to_i
  end

  def to_s
    [
      (completed ? :complete : :incomplete),
      @headers.to_s,
      @body
    ]
  end

  def code
    @headers.code
  end

  def message
    @headers.message
  end

  def version
    @headers.version
  end

  def [](key)
    @headers[key]
  end

  def query
    @headers.query
  end

  def path
    @headers.path
  end

  def cookies
    @headers.cookies
  end
end
