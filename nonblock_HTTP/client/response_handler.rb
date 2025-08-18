# frozen_string_literal: true

require 'erb'
require 'uri'
require_relative '../headers'

module NonBlockHTTP::Client; end

class NonBlockHTTP::Client::ResponseHandler < NonBlockHTTP::Headers
  attr_reader :completed, :message, :code, :version

  def initialize
    @completed = false
    @buffer = ''.dup
    super
  end

  def parse(data)
    return data if @completed

    @buffer << data
    return nil unless @buffer.include?(HEAD_TERM)

    raw_headers, leftover_data = @buffer.split(HEAD_TERM, 2)
    @headers = parse_headers(raw_headers)
    @buffer = ''.dup
    @completed = true
    leftover_data
  end

  def to_s
    @headers.to_h
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

    head[key.downcase] ||= []
    head[key.downcase] << value.strip
  end

  def parse_request_line(line)
    ver, cod, *msg = line.split
    @code = cod.to_i
    @version = ver.split('/').last
    @message = msg.join(' ').downcase
    { code: @code, message: @message, version: @version }
  end
end
