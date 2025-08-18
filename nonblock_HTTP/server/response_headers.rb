# frozen_string_literal: true

require_relative '../headers'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::ResponseHeaders < NonBlockHTTP::Headers
  DEFAULT_HTTP_CODES = {
    100 => 'Continue',
    101 => 'Switching Protocols',
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    203 => 'Non-Authoritative Information',
    204 => 'No Content',
    205 => 'Reset Content',
    206 => 'Partial Content',
    300 => 'Multiple Choices',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',
    305 => 'Use Proxy',
    307 => 'Temporary Redirect',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    407 => 'Proxy Authentication Required',
    408 => 'Request Timeout',
    409 => 'Conflict',
    410 => 'Gone',
    411 => 'Length Required',
    412 => 'Precondition Failed',
    413 => 'Payload Too Large',
    414 => 'URI Too Long',
    415 => 'Unsupported Media Type',
    416 => 'Range Not Satisfiable',
    417 => 'Expectation Failed',
    418 => "I'm a teapot",
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout',
    505 => 'HTTP Version Not Supported'
  }.freeze

  attr_reader :status, :version, :body

  def initialize(status: 200, version: '1.1')
    super()
    @status = status
    @version = version
  end

  def to_s
    header_to_string
  end

  def status=(code)
    code = code.to_i
    unless DEFAULT_HTTP_CODES.include?(code)
      raise "Unsupported HTTP Code #{code}. Available codes #{DEFAULT_HTTP_CODES}."
    end

    @status = code
  end

  private

  def top_line
    "HTTP/#{@version} #{status} #{status_message}"
  end

  def multiline?(key)
    MULTILINE_HEADERS.include?(key)
  end

  def map_header_value(key, values)
    return @header_lines << "#{title_header(key)}: #{values.join(', ')}" unless multiline?(key)

    values.each { |value| @header_lines << "#{title_header(key)}: #{value}" }
  end

  def status_message
    # add custom code handlers here
    DEFAULT_HTTP_CODES[status]
  end
end
