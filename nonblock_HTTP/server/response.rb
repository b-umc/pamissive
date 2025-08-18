# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'response_headers'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::Response
  attr_accessor :headers

  def initialize(**kwargs)
    update_body(kwargs[:body])
    @headers = NonBlockHTTP::Server::ResponseHeaders.new(**kwargs)
    keep_alive
  end

  def host
    @headers.host
  end

  def port
    @headers.port
  end

  def to_s
    header_string = @headers.to_s
    body_content = @body
    [header_string, body_content].join
  end

  def run
    to_s
  end

  def body=(data)
    update_body(data)
  end

  def status=(status)
    @headers.status = status
  end

  def close
    @headers['connection'] = 'close'
  end

  def keep_alive
    @headers['connection'] = 'keep-alive'
  end

  def close?
    @headers.close?
    !@headers.keep_alive?
  end

  def []=(key, value)
    @headers.add_header(key, value)
  end

  private

  def detect_content_type(body)
    str_body = body.to_s.strip
    return 'application/json' if str_body.start_with?('{', '[')
    return 'text/html' if str_body.start_with?('<')

    'text/plain'
  end

  def update_body(body)
    @body = body.to_s
    return if @body.empty?

    @headers.add_header('content-type', detect_content_type(@body))
    @headers.add_header('content-length', @body.bytesize)
  end
end
