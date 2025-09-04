# frozen_string_literal: true

require 'timeout'
require_relative '../logging/app_logger'
require_relative 'event_bus'

LOG = AppLogger.setup(STDOUT) unless defined?(LOG)

module TimeoutInterface
  def add_timeout(callback_proc, duration)
    SelectController.instance.add_timeout(callback_proc, duration)
  end

  def timeout?(callback_proc)
    SelectController.instance.timeout?(callback_proc)
  end

  def remove_timeout(callback_proc)
    SelectController.instance.remove_timeout(callback_proc)
  end
end

module SocketInterface
  def read_proc(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.readable?(sock)
  end

  def write_proc(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.writable?(sock)
  end

  def add_readable(readable_proc, sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.add_sock(readable_proc, sock)
  end

  def remove_readable(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.remove_sock(sock)
  end

  def add_writable(writable_proc, sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.add_sock(writable_proc, sock, for_write: true)
  end

  def remove_writable(sock)
    sock = sock.to_io if sock.respond_to?(:to_io)
    SelectController.instance.remove_sock(sock, for_write: true)
  end
end

module SelectHandlerMethods
  def handle_err(err_socks)
    return unless err_socks.is_a?(Array)

    LOG.debug([:error, err_socks])
    handle_readable(err_socks)
  end

  def handle_writable(writable)
    return unless writable.is_a?(Array)

    writable.each { |sock| call_with_timeout(@writable[sock]) if @writable[sock] }
  end

  def handle_readable(readable)
    return unless readable.is_a?(Array)

    readable.each { |sock| call_with_timeout(@readable[sock]) if @readable[sock] }
  end

  def handle_timeouts
    current_time = Time.now
    touts = @timeouts.keys
    touts.each do |callback_proc|
      # LOG.debug callback_proc
      timeout = @timeouts[callback_proc]
      next unless current_time >= timeout

      @timeouts.delete(callback_proc)
      call_with_timeout(callback_proc)
    end
  end
end

class SelectController
  MAX_SOCKS = 50
  CALL_TIMEOUT = 2
  @instance = nil
  class << self
    def instance
      @instance ||= new
    end

    def run
      instance.run
    end
  end
  private_class_method :new

  include SelectHandlerMethods

  def initialize
    reset
  end

  def readable?(sock)
    @readable[sock]
  end

  def writable?(sock)
    @writable[sock]
  end

  def add_sock(call_proc, sock, for_write: false)
    raise "IO type required for socket argument: #{sock.class}" unless sock.is_a?(IO)
    raise "invalid proc detected: #{call_proc.class}" unless call_proc.respond_to?(:call)

    for_write ? @writable[sock] = call_proc : @readable[sock] = call_proc
  end

  def remove_sock(sock, for_write: false)
    # LOG.debug(["removing_#{for_write ? 'write' : 'read'}_socket", sock, sock.object_id])
    for_write ? @writable.delete(sock) : @readable.delete(sock)
  end

  def remove_readables(socks)
    socks.each { |sock| remove_sock(sock) }
    @writable.each_key { |sock| remove_sock(sock, for_write: true) }
  end

  def stop
    remove_readables(@readable.keys)
  end

  def timeout?(callback_proc)
    @timeouts[callback_proc]
  end

  def add_timeout(callback_proc, seconds)
    # LOG.debug callback_proc
    # raise 'positive value required for seconds parameter' unless seconds.positive?
    raise "invalid proc detected: #{callback_proc.class}" unless callback_proc.respond_to?(:call)

    @timeouts[callback_proc] = Time.now + seconds
  end

  def remove_timeout(callback_proc)
    @timeouts.delete(callback_proc)
  end

  def reset
    @readable = {}
    @writable = {}
    @timeouts = {}
    at_exit do
      stop
    end
  end

  def run
    LOG.info [:select_controller, :loop_start, :pid, Process.pid]
    loop { select_socks }
    # $stdout.puts([Time.now, 'ok', Process.pid])
  rescue StandardError => e
    # Print directly to standard error to guarantee visibility
    STDERR.puts "--- Uncaught Exception in SelectController ---"
    STDERR.puts "Error: #{e.class}: #{e.message}"
    STDERR.puts "Backtrace:"
    e.backtrace.each { |line| STDERR.puts "  #{line}" }
    STDERR.puts "--------------------------------------------"

    # Also log to the file for a persistent record
    LOG.error([:uncaught_exception_while_select, e])
    LOG.error("Backtrace:\n\t#{e.backtrace.join("\n\t")}")

    # Use `abort` which is a more standard way to exit on a fatal error.
    # It also gives a chance for any final cleanup.
    abort("Exiting due to a fatal error.")
  end

  private

  def call_with_timeout(callback_proc)
    Timeout.timeout(CALL_TIMEOUT) { callback_proc.call }
  rescue Timeout::Error => e
    desc = if callback_proc.respond_to?(:source_location) && callback_proc.source_location
             file, line = callback_proc.source_location
             "#{file}:#{line}"
           elsif callback_proc.respond_to?(:receiver) && callback_proc.respond_to?(:name)
             "#{callback_proc.receiver.class}##{callback_proc.name}"
           else
             callback_proc.inspect
           end
    raise Timeout::Error, "callback #{desc} exceeded #{CALL_TIMEOUT} seconds", e.backtrace
  end

  def readables
    @readable.delete_if { |socket, _| socket.closed? }
    @readable.keys
  end

  def writeables
    @writable.delete_if { |socket, _| socket.closed? }
    @writable.keys
  end

  # def socks
  #   @readable.delete_if { |socket, _| socket.closed? }
  #   @readable.keys
  # end

  def run_select
    rd = readables
    raise "socks limit #{MAX_SOCKS} exceeded in select loop." if rd.length > MAX_SOCKS

    select(rd, writeables, rd, calculate_next_timeout)
  rescue IOError => e
    LOG.error([:io_error_in_select, e])
  end

  def select_socks
    # LOG.debug @readable
    readable, writable, err = run_select
    # LOG.debug readable
    return handle_err(err) if err && !err.empty?

    handle_timeouts
    handle_writable(writable) if writable
    handle_readable(readable) if readable
  end

  def calculate_next_timeout
    tnow = Time.now
    return nil if @timeouts.empty?

    [@timeouts.values.min, tnow].max - tnow
  end
end

# SelectController.instance.setup
