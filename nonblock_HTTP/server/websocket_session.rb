# frozen_string_literal: true

require 'websocket/driver'

module NonBlockHTTP; end
module NonBlockHTTP::Server; end

class NonBlockHTTP::Server::WebsocketSession
  include TimeoutInterface
  attr_accessor :message_handler, :close_handler

  def initialize(socket, raw, handler)
    @close_handler = nil
    @socket = socket
    @driver = WebSocket::Driver.server(self)
    @message_handler = handler
    @driver.on(:open)    { |e| handle_open(e) }
    @driver.on(:message) { |e| handle_message(e.data) }
    @driver.on(:close)   { |e| handle_close(e) }

    setup_handlers

    @driver.start
    receive_data(raw, nil)
    # send_message({ type: :notification, content: :welcome }.to_json)
    ping
  end

  def ping
    @driver.ping('ping')
    add_timeout(method(:ping), 30)
  end

  # Read data into the driver for frame parsing
  def receive_data(data, _)
    @driver.parse(data)
  end

  # Send a message through the driver
  def send_message(message)
    @driver.text(message)
  end

  # WebSocket::Driver requires write and close methods
  def write(data)
    @socket.write(data)
  end

  def closed?
    @socket.closed?
  end

  def close
    @socket.close
  end

  def send_js(code_string)
    send_message(
      {
        type: :js,
        code: code_string
      }.to_json
    )
  end

  private

  def setup_handlers
    @socket.handlers[:data] = method(:receive_data)
  end

  def handle_open(_event)
    LOG.debug([:WebSocket_connection_opened, object_id])
  end

  def handle_message(data)
    LOG.debug([:handle_incoming_from_ws, data[0..100]])
    @message_handler.call(data, self)
  end

  def handle_close(_event)
    @close_handler.call(self) if @close_handler.respond_to?(:call)
    LOG.debug([:WebSocket_connection_closed, object_id, @close_handler])
  end
end
