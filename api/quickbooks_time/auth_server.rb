# frozen_string_literal: true

require 'json'
require 'uri'
require 'securerandom'
require 'jwt'
require 'envkey'
require 'time'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../../nonblock_HTTP/manager'
require_relative '../../env/token_manager'

class QuickbooksTime; end
class QuickbooksTime::AuthServer; end

module QuickbooksTime::AuthServer::QuickbooksTimeConstants
  POPUP_CLOSE = <<~HTML
    <html>
    <head><title>Close Popup</title></head>
    <body>
      <script>
        window.onload = function() {
          // Check if the current window is a popup and not the main window
          if (window.opener) {
            window.close(); // Close the current popup window
          } else {
            document.body.innerHTML = '<p>This page is not in a popup and cannot be closed automatically.</p>';
          }
        }
      </script>
    </body>
    </html>
  HTML
  EVENT_BUS_PATH = 'quickbooks_time_auth'
  CREATE_TABLE_COMMANDS = {
    'api_sync_logs_constraint' => %{
          ALTER TABLE api_sync_logs
          ADD CONSTRAINT api_name_unique UNIQUE (api_name);
        }
  }.freeze
  QBT_CLIENT_ID = ENV.fetch('QBT_CLIENT_ID', nil)
  QBT_CLIENT_SECRET = ENV.fetch('QBT_CLIENT_SECRET', nil)
  QBT_TOKEN_SECRET = ENV.fetch('QBT_TOKEN_SECRET', nil)
  REDIRECT_URI = ENV.fetch('QBT_TOKEN_SECRET', nil)
  AUTHORIZATION_BASE_URL = 'https://rest.tsheets.com/api/v1/authorize'
  TOKEN_URL = 'https://rest.tsheets.com/api/v1/grant'
  HEADERS = {
    'content-type' => 'application/x-www-form-urlencoded',
    'accept' => 'application/json'
  }.freeze
end

class QuickbooksTime::AuthServer
  include QuickbooksTimeConstants
  include TimeoutInterface

  attr_reader :token

  def initialize(server, authed)
    @authed = authed
    @realm_id = nil
    @server = server
    retrieve_token
    publish_token_state
    @server.on('/quickbooks_time/oauth2callback', method(:oauth2_handler))
  end

  def invalidate_token

  end

  def status
    @token&.valid?
  end

  def auth_url
    "#{AUTHORIZATION_BASE_URL}?#{URI.encode_www_form(login_params)}"
  end

  private

  def login_params
    {
      client_id: QBT_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      # scope: LOGIN_SCOPE, # Not currently required by api
      state: generate_state
    }
  end

  def generate_state
    URI.encode_www_form_component(
      {
        nonce: SecureRandom.hex,
        timestamp: Time.now.to_i
      }.to_json
    )
  end

  def access_token_body(auth_code)
    URI.encode_www_form(
      {
        grant_type: 'authorization_code',
        code: auth_code,
        redirect_uri: REDIRECT_URI,
        client_id: QBT_CLIENT_ID,
        client_secret: QBT_CLIENT_SECRET
      }
    )
  end

  def oauth2_handler(req, res, &block)
    @realm_id = req.query['realmId']

    options = { body: access_token_body(req.query['code']), headers: HEADERS }

    LOG.debug([:quickbooks_time_requesting_from_token_url, TOKEN_URL, options, :based_on, res])

    NonBlockHTTP::Client::ClientSession.new.post(TOKEN_URL, options, log_debug: true) do |response|
      LOG.debug([:quickbooks_time_handling_response, response.body])
      handle_token_response(response, res, &block)
    end
  end

  def retrieve_token
    return unless (@token = TOK['quickbooks_time'])

    LOG.debug([:quickbooks_time_token_expires_in, @token.expires_in])
    add_timeout(method(:refresh_access_token), [@token.expires_in - 1000, 1].max)
  end

  def refresh_token_body
    URI.encode_www_form(
      grant_type: 'refresh_token',
      refresh_token: @token.refresh_token,
      client_id: QBT_CLIENT_ID,
      client_secret: QBT_CLIENT_SECRET
    )
  end

  def refresh_access_token
    return unless @token.refresh_token

    NonBlockHTTP::Client::ClientSession.new.post(
      TOKEN_URL, { body: refresh_token_body, headers: HEADERS }, log_debug: true
    ) do |response|
      handle_token_response(response, nil)
    end
  end

  def handle_token_response(response, res, &block)
    dat = token_response_code(response)
    return unless res

    res.status, res.body = dat
    res.close
    block.call(res)
  end

  def token_response_code(response)
    LOG.debug([:handling_token_response, response])
    return token_aquired(response) if response.code == 200

    LOG.error("Authentication failed: #{response.body}")
    TOK.delete_token(@token) { |res| LOG.debug([:token_delete_result, res]) }
    [500, 'Error in authentication process.']
  end

  def publish_token_state
    EventBus.publish(EVENT_BUS_PATH, 'authorization', { authorized: @token&.valid? })
    @authed.call(self) if @token&.valid?
  end

  def token_aquired(response)
    parse_token(response)
    TOK.store_token(@token) { |result| store_token_result(result) }
    LOG.debug('QuickbooksTime Token Aquired')
    [200, POPUP_CLOSE]
    publish_token_state
  end

  def store_token_result(result)
    return LOG.debug("Refresh token stored successfully: #{result}") if result

    @token = nil
    publish_token_state
  end

  def parse_token(response)
    @token = AuthToken.new('quickbooks_time', JSON.parse(response.body))
    add_timeout(method(:retrieve_token), @token.expires_in - 100)
  end
end

# Test
# require_relative 'load './ruby_nonblock/api/quickbooks_time/auth_server.rb'; @server = NonBlockHTTP::Manager.server(port: 8080); @auth = QuickbooksTime::AuthServer.new(@server, proc {|*dat| p([:authorized, dat])}); SelectController.run