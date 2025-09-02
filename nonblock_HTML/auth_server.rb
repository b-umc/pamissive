# frozen_string_literal: true

require 'erb'
require 'json'
require 'securerandom'
require_relative '../api/google/google_auth'
require_relative 'auth_session'
require_relative '../nonblock_socket/select_controller'
require_relative '../nonblock_socket/event_bus'
require_relative '../api/missive/missive'
require_relative '../env/token_manager' # Ensure DB is loaded

class NonBlockHTML::Server; end

class NonBlockHTML::Server::AuthServer
  include TimeoutInterface

  STATUS_DIV = ERB.new(%(
    <div id="status">
      <span hx-target="status"><%= status_message %></span>
    </div>
  ))

  FETCH_SESSION = %[
    const socket = event.detail.socketWrapper;

    Missive.storeGet('sessionData')
      .then(data => {
        console.log(data);
        let sess = localStorage.getItem('session_data') || {};
        socket.send(JSON.stringify({'session_data': {'local': sess, 'missive': data || {}}}));
      });
  ]

  def initialize(callback:, port: 8080)
    @authed_callback = callback
    @server = NonBlockHTTP::Manager.server(port: port)
    @server.on('/', method(:auth_hook))
    @server.on('/auth/ws', method(:auth_ws))
    @server.on('/default-icon.png', method(:serve_icon))
    @google_auth = API::Google::GoogleAuth.new(@server)
    @sockets = []
    @sessions = []
  end

  def on_message(data, wsock)
    LOG.debug(@sockets.map { |e| [e.object_id, e.closed?] })
    JSON.parse(data).each do |k, v|
      next session_data(v, wsock) if k == 'session_data'
      # Ignore non-auth messages that may be sent by the Missive UI client
      LOG.debug([:auth_ws_ignoring_message_key, k])
    end
  end

  def session_data(ses_dat, wsock)
    id = ses_dat['local']
    id = ses_dat['missive'] if id.empty?
    return unless wsock

    id = setup_session(wsock) if id.empty?
    session(id).update_sock(wsock)
  end

  def session(id)
    @sessions.find { |e| e.id == id } ||
      NonBlockHTML::Server::AuthServer::AuthSession
        .new(id, @google_auth, @authed_callback)
        .tap do |new_session|
          @sessions << new_session
          LOG.debug([:new_session_added, :session_count, @sessions.length])
        end
  end

  def setup_session(wsock)
    id = generate_session_id
    wsock.send_js("
      localStorage.setItem('session_data', '#{id}');
      Missive.storeSet('sessionData', '#{id}');
      ")
    id
  end

  private

  def generate_session_id
    SecureRandom.hex(16)
  end

  def auth_hook(_req, res)
    res.body = File.read([__dir__, '/client_auth.html'].join)
    res.status = 200
    res.close
    false
  end

  def auth_ws(req, _res = nil)
    wsock = NonBlockHTTP::Server::WebsocketSession.new(
      req.session.client, req.raw, proc { |data| on_message(data, wsock) }
    )
    wsock.close_handler = proc { |ws| @sockets.delete(ws) }
    @sockets << wsock
    LOG.debug([:new_ws_added, :ws_count, @sockets.length, :session_count, @sessions.length])
    @sockets.reject!(&:closed?)
    wsock.send_js(FETCH_SESSION)
  end

  def serve_icon(_req, res)
    res.body = '' # File.read([__dir__, '/cropped-faicon2-32x32.png'].join)
    res.status = 200
    res.close
    false
  end

  # Missive webhook handler removed. Verification is handled via polling.
end
