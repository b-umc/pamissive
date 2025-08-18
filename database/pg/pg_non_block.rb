# frozen_string_literal: true

require 'pg'
require_relative '../../nonblock_socket/select_controller'

class PGNonBlock
  include SocketInterface

  def initialize(db_params)
    @wait_read = false
    @connection = PG.connect(db_params)
    @connection.setnonblocking(true)
    @requests = []
    @callbacks = []
  end

  def prepare(name, query, &block)
    enqueue_request(proc {
      @connection.send_prepare(name, query)
    }, block)
  end

  def exec_prepared(name, params, &block)
    enqueue_request(proc {
      # LOG.debug([:exec_prepared, name, params])
      @connection.send_query_prepared(name, params)
    }, block)
  end

  def exec(query, &block)
    enqueue_request(proc {
      @connection.send_query(query)
    }, block)
  end

  def exec_params(query, params, &block)
    enqueue_request(proc {
      @connection.send_query_params(query, params)
    }, block)
  end

  def close
    @callbacks.clear
    @connection.close
  end

  def format_value(value)
    case value
    when Array, Hash then "'#{@connection.escape_string(value.to_json)}'"
    when String then "'#{@connection.escape_string(value)}'"
    when Time then "'#{value.strftime('%Y-%m-%dT%H:%M:%S')}'"
    when NilClass then 'NULL'
    else value.to_s
    end
  end

  private

  def enqueue_request(request_proc, callback)
    @requests.push(proc {
      request_proc.call
      @callbacks.push(callback || method(:log_reply))
      add_readable(method(:next_readable), sock)
    })
    add_writable(method(:next_writable), sock) unless @wait_read
  end

  def pg_error(message)
    LOG.error(message)
    @callbacks.each { |callback| callback.call(nil, message) }
    @callbacks.clear
    @requests.clear
  end

  def handle_results
    result = @connection.get_last_result
    @callbacks.shift.call(result)
  end

  def next_readable
    @connection.consume_input

    results = []
    while (res = @connection.get_result)
      results << res
    end

    if results.any?
      cb = @callbacks.shift
      cb&.call(results.last)
    end
  rescue PG::Error => e
    pg_error("Database error: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}")
  ensure
    add_writable(method(:next_writable), sock) unless @requests.empty?
    remove_readable(sock) && @wait_read = false unless @connection.is_busy
  end

  def next_writable
    req = @requests.shift
    req.call
    add_readable(method(:next_readable), sock)
  rescue PG::Error => e
    pg_error("Database write error: #{e.message}")
  ensure
    remove_writable(sock)
    @wait_read = true
  end

  def sock
    @connection.socket_io
  end

  def log_reply(*data)
    # LOG.debug(data)
  end
end
