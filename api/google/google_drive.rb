# frozen_string_literal: true

require 'json'
require 'uri'

module API; end

module API::Google; end

class API::Google::GoogleDrive
  API_ENDPOINT = 'https://www.googleapis.com/drive/v3'

  def initialize(access_token, refresh_token, auth)
    @access_token = access_token
    @refresh_token = refresh_token
    @auth = auth
    @expires_at = Time.now + 3600 # Assuming token expires in 1 hour
  end

  def list_files(options = {}, &callback)
    ensure_valid_token do
      url = "#{API_ENDPOINT}/files"
      headers = {
        'Authorization' => "Bearer #{@access_token}",
        'Accept' => 'application/json'
      }

      params = options.map { |k, v| "#{k}=#{URI.encode_www_form_component(v)}" }.join('&')
      url += "?#{params}" unless params.empty?

      client = NonBlockHTTP::Client::ClientSession.new
      client.get(url, headers: headers) do |response|
        if response.status == 200
          files = JSON.parse(response.body)
          callback.call(files)
        else
          LOG.error("Error listing files: #{response.status} - #{response.body}")
          callback.call(nil)
        end
      end
    end
  end

  # Additional methods like upload_file, download_file, etc., can be implemented similarly.

  private

  def ensure_valid_token(&block)
    if token_expired?
      @auth.refresh_access_token(@refresh_token) do |new_tokens|
        if new_tokens
          @access_token = new_tokens['access_token']
          @expires_at = Time.now + new_tokens['expires_in'].to_i
          block.call
        else
          LOG.error('Failed to refresh access token.')
          # Handle re-authentication if necessary
        end
      end
    else
      block.call
    end
  end

  def token_expired?
    Time.now >= @expires_at
  end
end
