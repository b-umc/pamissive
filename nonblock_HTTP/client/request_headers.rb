# frozen_string_literal: true

require_relative '../headers'

module NonBlockHTTP::Client; end

class NonBlockHTTP::Client::RequestHeaders < NonBlockHTTP::Headers
  DEFAULT_AGENT = ['RubyNonBlockHTTPClient/1.0'].freeze
  DEFAULT_ACCEPT = ['text/html'].freeze
  DEFAULT_CONTENT_TYPE = ['text/plain'].freeze
  DEFUALT_CONNECTION = ['close'].freeze
  DEFAULT_VERSION = '1.1'
  VERBS = %w[GET POST PUT DELETE PATCH HEAD OPTIONS CONNECT TRACE].freeze
  DATA_VERBS = %w[POST PUT PATCH].freeze

  attr_reader :uri, :version

  def initialize(url, options: {}, verb: nil)
    super(options[:headers])
    @uri = URI(url)
    update_query(options[:query])
    update_verb(verb) if verb
    @version = options[:version] || DEFAULT_VERSION
  end

  def ssl?
    @uri.scheme == 'https'
  end

  def query
    @uri&.query
  end

  def path
    @uri&.path
  end

  def port
    @uri&.port
  end

  def host
    @uri&.host
  end

  def to_s(size = 0)
    @head_map = {}
    add_base_headers(size)
    header_to_string(@head_map)
  end

  def query=(query_hash)
    @uri.query = nil
    update_query(query_hash) if query_hash
  end

  def verb=(verb_data)
    update_verb(verb_data) if verb_data
  end

  def verb
    @verb || (length?.positive? ? 'POST' : 'GET')
  end

  private

  def add_content_type_header
    return unless DATA_VERBS.include?(@verb)

    @head_map['content-type'] = DEFAULT_CONTENT_TYPE unless @headers['content-type']
  end

  def add_base_headers(size)
    @head_map['host'] = [@uri.host] unless @headers['host']
    @head_map['user-agent'] = DEFAULT_AGENT unless @headers['user_agent']
    @head_map['connection'] = DEFUALT_CONNECTION unless @headers['connection']
    @head_map['accept'] = DEFAULT_ACCEPT unless @headers['accept']
    @head_map['content-length'] = [size] if size.positive?
    add_content_type_header
  end

  def update_query(query_data)
    @query = query_data
    return unless @query

    @uri.query = URI.encode_www_form(query_data)
  end

  def update_verb(verb_data)
    v = verb_data.to_s.upcase.strip
    return @verb = v if VERBS.include?(v)

    raise(
      ArgumentError,
      "Invalid HTTP Verb: '#{verb_data}'. Valid verbs are: #{VERBS}"
    )
  end

  def top_line
    "#{verb} #{@uri.request_uri} HTTP/#{@version}"
  end

  def multiline?(key)
    MULTILINE_HEADERS.include?(key)
  end

  def map_header_value(key, values)
    return @header_lines << "#{title_header(key)}: #{values.join(', ')}" unless multiline?(key)

    values.each { |value| @header_lines << "#{title_header(key)}: #{value}" }
  end
end
