# frozen_string_literal: true

require 'uri'

module NonBlockHTTP; end

class NonBlockHTTP::Headers
  LINE_TERM = "\r\n"
  HEAD_TERM = "\r\n\r\n"
  MULTILINE_HEADERS = ['set-cookie'].freeze

  attr_reader :headers, :cookies

  def initialize(headers = {})
    @cookies = {}
    @headers = {}
    add_headers(headers) if headers.respond_to?(:each)
  end

  def to_h
    @headers
  end

  def [](key)
    v = @headers[key.to_s.downcase]
    v&.length == 1 ? v.first : v
  end

  def []=(key, value)
    @headers[key.to_s.downcase] = [value].flatten unless value.nil?
  end

  def add_header(key, value)
    @headers[key.downcase] ||= []
    @headers[key.downcase] << value.to_s.strip
  end

  def add_headers(header_hash)
    header_hash.each { |k, v| add_header(k, v) }
  end

  def length?
    @headers['content-length']&.first&.to_i
  end

  def chunked?
    @headers['transfer-encoding']&.first&.casecmp?('chunked')
  end

  def keep_alive?
    self['connection'] == 'keep-alive'
  end

  def close?
    self['connection'] != 'keep-alive'
  end

  private

  def header_to_string(base_headers = {})
    @header_lines = [top_line]
    @headers.each { |key, values| map_header_value(key, values) }
    base_headers.each { |key, values| map_header_value(key, values) }
    @header_lines.join(LINE_TERM) + HEAD_TERM
  end

  def top_line; end

  def map_header_value; end

  def title_header(header)
    header.to_s.split('-').map(&:capitalize).join('-')
  end
end
