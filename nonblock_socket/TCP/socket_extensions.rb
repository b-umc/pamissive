# frozen_string_literal: true

require_relative '../select_controller'

module NonBlockSocket; end
module NonBlockSocket::TCP; end
module NonBlockSocket::TCP::SocketExtensions; end

module NonBlockSocket::TCP::SocketExtensions::SocketIO
  CHUNK_LENGTH = 1024 * 16

  def write(data)
    @output_table ||= []
    @output_table << data
    return if @wait_io

    add_writable(method(:write_message), to_io)
    # LOG.debug([:added_to_write_queue, data])
  end

  private

  def read_chunk
    # LOG.debug(['reading'])
    s = to_sock
    dat = s.read_nonblock(CHUNK_LENGTH, exception: false)
    return if dat == :wait_readable
    return on_disconnect if dat.nil? || dat.empty?

    handle_data(dat)
    dat = nil
    begin
      on_disconnect if s.eof?
    rescue IOError
      on_disconnect
    end
  rescue EOFError, Errno::EPIPE, Errno::ECONNREFUSED, Errno::ECONNRESET => e
    on_disconnect(dat)
    on_error(e, e.backtrace)
  rescue IOError
    on_disconnect(dat)
  rescue IO::WaitReadable
    # IO not ready yet
  end

  def write_chunk
    # LOG.debug(['writing', @write_buffer])
    written = to_sock.write_nonblock(@write_buffer)
    # LOG.debug(['wrote', written])
    @write_buffer = @write_buffer[written..]
  rescue EOFError, Errno::EPIPE, Errno::ECONNREFUSED, Errno::ECONNRESET => e
    on_error(e, e.backtrace)
    on_disconnect
  rescue IO::WaitWritable
    # IO not ready yet
  end

  def write_message
    setup_buffers unless @write_buffer
    return next_write unless @write_buffer.empty?
    return if @output_table.empty?

    @write_buffer << @output_table.shift
    @current_output = @write_buffer
    write_chunk
    next_write
  end

  def next_write
    setup_buffers unless @write_buffer
    on_wrote(@current_output) if @write_buffer.empty?
    return unless @output_table.empty?

    on_emtpy
    remove_writable(to_io)
    close if @close_after_write
  end
end

module NonBlockSocket::TCP::SocketExtensions::Events
  def trigger_event(event_name, *args)
    handler = @handlers[event_name]
    handler&.call(*args)
  end

  def on_emtpy
    trigger_event(:emtpy)
  end

  def on_error(error, backtrace)
    LOG.error([error, backtrace])
    @error_status = [error, backtrace]
    trigger_event(:error, @error_status, self)
  end

  def on_connect
    @disconnected = false
    add_readable(method(:read_chunk), to_io)
    next_write
    trigger_event(:connect, self)
  end

  def on_disconnect(dat = nil)
    @disconnected = true
    on_data(dat) if dat
    remove_readable(to_io)
    remove_writable(to_io)
    close unless closed?
    trigger_event(:disconnect, self)
  end

  def on_data(data)
    trigger_event(:data, data, self)
  end

  def on_message(message)
    trigger_event(:message, message, self)
  end

  def on_wrote(message)
    return unless message

    @current_output&.clear
    trigger_event(:wrote, message, self)
  end
end

class MessagePattern
  attr_accessor :pattern

  def initialize(callback, pattern = /(.*)\n/)
    @callback = callback
    @pattern = pattern
  end

  def call(message, client)
    @callback.call(message, client)
  end
end

module NonBlockSocket::TCP::SocketExtensions
  include Events
  include SocketIO
  include SocketInterface
  include TimeoutInterface

  DEFAULT_BUFFER_LIMIT = 1024 * 16
  DEFAULT_BUFFER_TIMEOUT = 2

  attr_accessor :handlers, :read_buffer_timeout, :max_buffer_size

  def connected
    setup_buffers
    @handlers ||= {}
    on_connect
  end

  def add_handlers(handlers)
    handlers.each { |event, proc| on(event, proc) }
  end

  def on(event, proc = nil, &block)
    @handlers ||= {}
    @handlers[event] = proc || block
  end

  def to_io
    @socket
  end

  def to_sock
    @socket
  end

  def closed?
    to_sock ? to_sock.closed? : true
  end

  def close
    return if closed?

    to_sock.close
    on_disconnect unless @disconnected
  end

  private

  def setup_buffers
    @input_buffer ||= ''.dup
    @output_table ||= []
    @write_buffer ||= ''.dup
    @read_buffer_timeout ||= DEFAULT_BUFFER_TIMEOUT
    @max_buffer_size ||= DEFAULT_BUFFER_LIMIT
  end

  def handle_data(data)
    add_timeout(method(:handle_read_timeout), @read_buffer_timeout)
    # LOG.debug([:handle_socket_data, object_id, data])
    on_data(data)
    handle_message(data)
  end

  def handle_message(data)
    return unless (on_msg = @handlers[:message])
    return unless (pattern = on_msg.pattern)

    @input_buffer << data
    handle_buffer_overrun
    while (line = @input_buffer.slice!(pattern))
      on_message(line)
    end
  end

  class BufferOverrunError < StandardError; end

  def handle_buffer_overrun
    return unless @input_buffer.size > @max_buffer_size

    close
    raise BufferOverrunError, "Read buffer size exceeded for client: #{self}"
  end

  def handle_read_timeout
    return if @input_buffer.empty?

    LOG.info(["Read timeout reached for client: #{self}, clearing data from buffer: ", @input_buffer])
    @input_buffer = ''.dup
  end
end

class NonBlockSocket::TCP::Wrapper
  include NonBlockSocket::TCP::SocketExtensions

  def initialize(socket)
    @wait_io = false
    @socket = socket
    connected
  end
end
