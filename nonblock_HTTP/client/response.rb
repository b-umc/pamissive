# frozen_string_literal: true

require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'response_handler'

module NonBlockHTTP::Client; end

class NonBlockHTTP::Client::Response
  attr_reader :headers, :completed

  def initialize(data = nil)
    @headers = NonBlockHTTP::Client::ResponseHandler.new
    @body = ''.dup
    @working_chunk = 0
    @working_chunks = [''.dup]
    @working_size = 0
    @working_length = nil
    @buffer = ''.dup
    parse(data)
  end

  def body
    @body = @working_chunks.join if @body.nil? || @body.empty?
    @body
  end

  def []=(key, value)
    @headers.add_header(key, value)
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

  def close?
    @headers.close?
  end

  def parse(data)
    data = data.to_s
    return if data.empty?

    # LOG.debug(:data_available_for_parsing)
    data = @headers.parse(data)
    return unless @headers.completed

    # LOG.debug(:body_data_available_for_parsing)
    return parse_body(data, @headers.length?) if @headers.length?
    return parse_chunks(data) if @headers.chunked?

    @completed = true
  end

  private

  def parse_body(data, size)
    @body << data.strip
    @working_size += data.b.length
    @completed = (@working_size >= size)
  end

  def parse_chunks(input_data)
    data = @buffer + input_data.to_s
    @buffer = ''.dup

    while data && !data.empty?
      unless @working_length
        data = split_chunk(data)
        break unless data
        return final_chunk if @working_length.zero?
      end

      remaining_length = @working_length - @working_chunk
      idx = @working_chunks.length - 1
      @working_chunks[idx] << data.byteslice(0, remaining_length)

      consumed = [data.bytesize, remaining_length].min
      @working_chunk += consumed
      if consumed < remaining_length
        data = nil
        break
      end

      if data.bytesize < remaining_length + 2
        @buffer = data.byteslice(remaining_length..) || ''.dup
        data = nil
        break
      end

      data = next_chunk(data, remaining_length)
    end

    @buffer << data if data && !data.empty?
  end

  def next_chunk(data, consumed)
    @working_chunks << ''.dup
    data = data.byteslice(consumed + 2..)
    @working_length = nil
    @working_chunk = 0
    data
  end

  def final_chunk
    @completed = true
    @body = @working_chunks.join
  end

  def split_chunk(data)
    return unless data
    return data if @working_length

    if (idx = data.index("\r\n"))
      len = data.byteslice(0, idx)
      @working_length = len.to_i(16)
      @working_chunk = 0
      data.byteslice(idx + 2..)
    else
      @buffer << data
      nil
    end
  end
end
