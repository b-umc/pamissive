# frozen_string_literal: true

require 'erb'
require 'json'
require_relative '../nonblock_socket/select_controller'

module NonBlockHTML; end

class NonBlockHTML::Server; end
class NonBlockHTML::Server::AuthServer; end

class NonBlockHTML::Server::AuthServer::AuthSession
  include TimeoutInterface

  GOOGLE_AUTH_LAUNCHER = %(
    <div id="google_auth" >
      <button class="button" ws-send hx-vals='{"oauth":"login"}'>Login to Jobsites</button>
    </div>
  )

  GOOGLE_AUTH_COMPLETE = %(
    <div id="google_auth">
    </div>
  )

  STATUS_DIV = ERB.new(%(
    <div hx-swap-oob="beforeend:#status">
      <span hx-target="status"><%= status_message %></span>
    </div>
  ))

  FETCH_USERS = %[
    const socket = event.detail.socketWrapper;
    Missive.fetchUsers().then(users => {
      socket.send(JSON.stringify({'users_data': (users || [])}))
    });
  ]

  FETCH_SESSION = %[
    const socket = event.detail.socketWrapper;
    Missive.storeGet('session').then(session => {
      socket.send(JSON.stringify({'session_data': (session || {})}))
    });
  ]

  attr_reader :id, :ws, :token

  def initialize(id, google_auth, on_auth_callback)
    @id = id
    @google_auth = google_auth
    @authed_callback = on_auth_callback
    service = "google:#{id}"
    @token = TOK[service] || AuthToken.new(service)
  end

  def update_sock(wsock)
    @ws = wsock
    @ws.message_handler = method(:on_message)
    send_ping
    setup_missive_actions # Set up Missive UI actions
    return begin_oauth unless @token&.refresh_token

    refresh_token
  end

  def store_token(data)
    @ws.send_message(GOOGLE_AUTH_COMPLETE)
    @token.data = data
    TOK.store_token(@token) { |res| LOG.debug([:token_store_result, !res.nil?]) }
    add_timeout(method(:refresh_token), @token.expires_in)
    @authed_callback.call(self)
  end

  def oauth_result(_result, token_data)
    store_token(token_data)
    LOG.debug('Google Authorization Complete')
    @ws.send_js('Missive.reload();')
  end

  private

  def setup_missive_actions
    js_code = <<~JS
      try {
        Missive.setActions([
          {
            label: 'Open paired thread',
            contexts: ['comment'],
            callback: (ctx) => {
              const socket = event && event.detail && event.detail.socketWrapper;
              if (!socket) {
                console.error('WebSocket not found for Missive action.');
                return;
              }

              let payload = { cat: 'ctl', action: 'paired_navigation' };
              if (ctx && ctx.comment && ctx.comment.task && ctx.comment.task.id) {
                payload.task_id = ctx.comment.task.id;
              } else {
                const cid = (ctx && ctx.conversation && ctx.conversation.id) || (ctx && ctx.conversationId);
                if (!cid) return;
                payload.conversation_id = cid;
              }
              socket.send(JSON.stringify(payload));
            }
          },
          {
            label: 'Build Invoice…',
            contexts: ['conversation'],
            callback: (ctx) => {
              const socket = event && event.detail && event.detail.socketWrapper;
              if (!socket) {
                console.error('WebSocket not found for Missive action.');
                return;
              }
              const cid = (ctx && ctx.conversation && ctx.conversation.id) || (ctx && ctx.conversationId);
              socket.send(JSON.stringify({ cat: 'quickbooks_time', act: 'open_invoice', conversation_id: cid }));
            }
          },
          {
            label: 'Build Invoice (Full‑screen)…',
            contexts: ['conversation'],
            callback: (ctx) => {
              const socket = event && event.detail && event.detail.socketWrapper;
              if (!socket) {
                console.error('WebSocket not found for Missive action.');
                return;
              }
              const cid = (ctx && ctx.conversation && ctx.conversation.id) || (ctx && ctx.conversationId);
              const today = new Date();
              const to = new Date(today.getTime() - (0 * 24 * 60 * 60 * 1000)).toISOString().slice(0,10);
              const from = new Date(today.getTime() - (14 * 24 * 60 * 60 * 1000)).toISOString().slice(0,10);
              Missive.openForm({
                title: 'Invoice Builder — Filters',
                submitLabel: 'Next',
                cancelLabel: 'Cancel',
                message: 'Choose a date range, grouping and sorting. You will pick entries and rates on the next step.',
                fields: [
                  { id: 'from', label: 'From (YYYY-MM-DD)', type: 'text', value: from },
                  { id: 'to', label: 'To (YYYY-MM-DD)', type: 'text', value: to },
                  { id: 'sort', label: 'Sort', type: 'select', options: [
                    { label: 'Date', value: 'date' },
                    { label: 'Technician', value: 'tech' },
                    { label: 'Duration', value: 'duration' }
                  ], value: 'date' },
                  { id: 'group', label: 'Group', type: 'select', options: [
                    { label: 'By Technician', value: 'tech' },
                    { label: 'By Day', value: 'day' },
                    { label: 'By Week', value: 'week' }
                  ], value: 'tech' },
                  { id: 'preselect', label: 'Preselect all entries', type: 'checkbox', value: true }
                ],
                onSubmit: (vals) => {
                  socket.send(JSON.stringify({ cat: 'quickbooks_time', act: 'openform_step1', conversation_id: cid, params: vals }));
                }
              });
            }
          }
        ]);
      } catch (e) { console.error('setActions failed', e); }
    JS
    @ws.send_js(js_code)
  end

  def send_ping
    @ws.ping
    add_timeout(method(:send_ping), 30)
  end

  def begin_oauth
    @ws.send_message(GOOGLE_AUTH_LAUNCHER)
  end

  def refresh_token
    @google_auth.refresh_access_token(@token.refresh_token) do |result, token_data|
      next LOG.error([:error_refreshing_token, result]) unless token_data

      store_token(token_data)
      status('Google Token Refreshed')
    end
  end

  # Missive.alert({title: "openening auth url", message: '<a href="#{auth_url}" target="_blank">Login With Google</a>'});
  def open_oauth_url
    auth_url = @google_auth.oauth_url(@id, method(:oauth_result))
    @ws.send_js(%[
      let popup = window.open("#{auth_url}", "_blank");
      if (!popup || popup.closed || typeof popup.closed == 'undefined') {
        Missive.openURL('#{auth_url}');
        // Pop-up was blocked
        // alert("Pop-up blocked! Please allow pop-ups for this site in your browser settings.");
      } else {
        // Pop-up was successfully opened
        console.log("Pop-up successfully opened.");
      }
    ])
  end

  def on_message(data, _wsock)
    data = JSON.parse(data)
    return LOG.debug([:unhandled_request_in_auth, data.keys]) unless data['oauth']

    open_oauth_url
  end

  def status(message)
    status_message = [Time.now.asctime, message]

    @ws.send_message(STATUS_DIV.result(binding))
  end

  def generate_session_id
    SecureRandom.hex(16)
  end
end
