# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'jwt'
require 'envkey'
require 'erb'

module API; end

module API::Google; end

class API::Google::GoogleAuth
  include TimeoutInterface

  GAUTH_CLIENT_ID = ENV.fetch('GAUTH_CLIENT_ID', nil)
  GAUTH_CLIENT_SECRET = ENV.fetch('GAUTH_CLIENT_SECRET', nil)
  GAUTH_TOKEN_SECRET = ENV.fetch('GAUTH_TOKEN_SECRET', nil)
  REDIRECT_URI = 'https://jobsites.paramountautomation.com/oauth2callback'
  AUTHORIZATION_BASE_URL = 'https://accounts.google.com/o/oauth2/auth'
  TOKEN_URL = 'https://oauth2.googleapis.com/token'
  USER_INFO_URL = 'https://www.googleapis.com/oauth2/v3/userinfo'
  HEADERS = { 'Content-Type' => 'application/x-www-form-urlencoded' }.freeze

  OAUTH_CLOSE = %(
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>OAuth Success</title>
    </head>
    <body>
      <h1>Authentication Successful</h1>
      <p>Please close this window.</p>
      <script>
        window.onload = function () {
          open(location, '_self').close();
        };
      </script>
    </body>
    </html>
  )

  def initialize(server)
    @server = server
    @sessions = {}
    @valid_sessions = {}
    @server.on('/oauth2callback', method(:oauth2_handler))
  end

  def login_params(session)
    {
      client_id: GAUTH_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: 'openid email profile https://www.googleapis.com/auth/drive',
      state: URI.encode_www_form_component({ session: session }.to_json),
      access_type: 'offline',
      prompt: 'consent'
    }
  end

  def with_valid_token(&block)
    if token_expired?
      refresh_access_token(@session.token.refresh_token) do |new_token|
        if new_token
          @session.token.access_token = new_token['access_token']
          @session.token.expires_in = new_token['expires_in']
          block.call
        else
          @ws.send_message('Authentication error. Please log in again.')
        end
      end
    else
      block.call
    end
  end

  def login_params_old(session)
    {
      client_id: GAUTH_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: 'openid email profile',
      state: URI.encode_www_form_component({ session: session }.to_json),
      access_type: 'offline',
      prompt: 'consent'
    }
  end

  def oauth_url(session_id, callback)
    @sessions[session_id] = callback
    form = login_params(session_id)
    "#{AUTHORIZATION_BASE_URL}?#{URI.encode_www_form(form)}"
  end

  def oauth2_refresh_data(refresh_token)
    {
      client_id: GAUTH_CLIENT_ID,
      client_secret: GAUTH_CLIENT_SECRET,
      refresh_token: refresh_token,
      grant_type: 'refresh_token'
    }
  end

  def refresh_access_token(tok, &block)
    data = oauth2_refresh_data(tok)

    NonBlockHTTP::Client::ClientSession.new.post(
      TOKEN_URL, { body: URI.encode_www_form(data), headers: HEADERS }
    ) { |response| oauth2_refresh_handler(response, &block) }
  end

  def oauth2_refresh_handler(response, &block)
    return block.call(response, nil) unless response.code == 200

    tokens = JSON.parse(response.body)
    block.call(response, tokens)
  rescue JSON::ParserError => e
    [:google_auth_error_parsing_json_data, e, e.backtrace,
     response, response.body].each { |m| LOG.error(m) }
    nil
  end

  def oauth2_handler(req, res, &block)
    state_param = req.query['state']
    state = JSON.parse(URI.decode_www_form_component(state_param)) if state_param
    session_id = state['session']
    return res.status = 400 unless @sessions[session_id]

    data = oauth2_handler_data(req.query['code'])
    NonBlockHTTP::Client::ClientSession.new.post(
      TOKEN_URL, { body: URI.encode_www_form(data), headers: HEADERS }
    ) { |response| oauth2_token_handler(response, res, session_id, &block) }
  end

  def oauth2_handler_data(code)
    {
      code: code,
      client_id: GAUTH_CLIENT_ID,
      client_secret: GAUTH_CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
      grant_type: 'authorization_code'
    }
  end

  def oauth2_token_handler(response, res, session_id, &block)
    tokens = nil
    return oauth_error(res, &block) unless response.code == 200

    tokens = JSON.parse(response.body)
    res.status = 200
    res.body = OAUTH_CLOSE
    res.close
    block.call(res)
    true
  ensure
    @sessions[session_id].call(response.code, tokens)
    @sessions.delete(session_id)
  end

  def oauth_error(res, &block)
    LOG.error('OAuth Token Exchange Error')
    res.status = 500
    res.body = 'OAuth Token Exchange Error'
    block.call(res)
  end
end
