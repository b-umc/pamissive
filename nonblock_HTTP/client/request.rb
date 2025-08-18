# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'request_headers'

module NonBlockHTTP::Client; end

class NonBlockHTTP::Client::Request
  def initialize(url, options: {}, verb: nil)
    @headers = NonBlockHTTP::Client::RequestHeaders.new(url, options: options, verb: verb)
    @options = options
    update_body(options[:body])
  end

  def ssl_context
    @options[:ssl_context]
  end

  def query=(query_hash)
    @headers.update_query(query_hash)
  end

  def ssl?
    @headers.ssl?
  end

  def host
    @headers.host
  end

  def port
    @headers.port
  end

  def to_s
    body_content = @body.to_s
    header_string = @headers.to_s(body_content.bytesize)
    [header_string, body_content].join
  end

  def run
    to_s
  end

  def body=(data)
    update_body(data)
  end

  private

  def update_body(body)
    @body = body
  end
end
