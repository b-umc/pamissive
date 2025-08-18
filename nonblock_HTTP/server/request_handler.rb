# frozen_string_literal: true

require_relative '../headers'

module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::RequestHandler < NonBlockHTTP::Headers
  attr_reader :completed, :verb, :version, :uri, :headers

  def initialize
    @completed = false
    @buffer = ''.dup
    super
  end

  def parse(data)
    @buffer += data
    return nil unless @buffer.include?(HEAD_TERM)

    raw_headers, leftover_data = @buffer.split(HEAD_TERM, 2)
    @headers = parse_headers(raw_headers)
    @buffer = ''.dup
    @completed = true
    leftover_data
  end

  def query
    return {} unless @uri&.query

    URI.decode_www_form(@uri.query).to_h
  end

  def path
    @uri&.path
  end

  private

  def parse_headers(raw_headers)
    @raw = raw_headers
    request, *headers = raw_headers.split(LINE_TERM)
    head = parse_request_line(request)
    headers.each_with_object(head) { |line, h| add_line_to_head(line, h) }
  end

  def add_line_to_head(line, head)
    key, value = line.split(': ', 2)
    return if key.nil? || value.nil?

    key = key.downcase
    parse_cookies(value) if key == 'cookie'
    head[key] ||= []
    head[key] << value.strip
  end

  def parse_cookies(cookie_header)
    cookie_header.split(';').map(&:strip).each do |pair|
      key, value = pair.split('=', 2)
      next unless key && value

      @cookies[key] = value
    end
  end

  def parse_request_line(line)
    arr = line.split
    @verb = arr.shift.downcase
    @version = arr.pop.split('/').last
    @uri = URI.parse(arr.join('%20'))
    { uri: @uri, verb: @verb, version: @version }
  end
end
