# frozen_string_literal: true

require 'json'
require 'uri'
require_relative '../../nonblock_HTTP/client/session'
require_relative 'rate_limiter'
require_relative 'util/constants'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class QbtClient
  API_ENDPOINT = 'https://rest.tsheets.com/api/v1'

  def initialize(auth_token_provider = nil, limiter: RateLimiter.new(interval: Constants::QBT_RATE_INTERVAL))
    @token_provider = auth_token_provider
    @limiter = limiter
  end

  def timesheets_modified_since(timestamp_iso, page: 1, limit: 50, supplemental: true, &blk)
    params = {
      start_date: timestamp_iso.to_s[0, 10],
      modified_since: timestamp_iso,
      limit: limit,
      page: page
    }
    params[:supplemental_data] = supplemental ? 'yes' : 'no'
    api_request("timesheets?#{URI.encode_www_form(params)}", &blk)
  end

  def users(page:, limit:, &blk)
    params = { page: page, per_page: limit, active: 'both' }
    api_request("users?#{URI.encode_www_form(params)}", &blk)
  end

  def users_modified_since(timestamp_iso, page: 1, limit: 50, &blk)
    params = { modified_since: timestamp_iso, page: page, per_page: limit, active: 'both' }
    api_request("users?#{URI.encode_www_form(params)}", &blk)
  end

  def jobcodes(page:, limit:, &blk)
    params = { page: page, per_page: limit }
    api_request("jobcodes?#{URI.encode_www_form(params)}", &blk)
  end

  def jobcodes_modified_since(timestamp_iso, page: 1, limit: 50, &blk)
    params = { modified_since: timestamp_iso, page: page, per_page: limit }
    api_request("jobcodes?#{URI.encode_www_form(params)}", &blk)
  end

  private

  def api_request(endpoint, &blk)
    token = @token_provider&.call
    unless token
      LOG.error [:qbt_api_request_missing_token, endpoint]
      return blk.call(nil)
    end

    headers = { 'Authorization' => "Bearer #{token}" }
    url = "#{API_ENDPOINT}/#{endpoint}"
    LOG.debug [:qbt_api_request, url]

    @limiter.wait_until_allowed do
      NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }, log_debug: true) do |response|
      unless response
        LOG.error [:qbt_api_request_failed, endpoint, :no_response]
        blk.call(nil)
        next
      end

      if response.code == 404 && endpoint.start_with?('timesheets')
        blk.call({ 'results' => { 'timesheets' => {} }, 'more' => false })
        next
      end

      unless response.code == 200
        error_body = begin
          response.body
        rescue StandardError
          nil
        end
        LOG.error [:qbt_api_request_failed, endpoint, response.code, error_body].compact
        blk.call(nil)
        next
      end

      begin
        data = JSON.parse(response.body)
        size = data.dig('results', 'jobcodes')&.size || data.dig('results', 'timesheets')&.size
        LOG.debug [:qbt_api_response, endpoint, :more, data['more'], :count, size]
        blk.call(data)
      rescue JSON::ParserError
        LOG.error [:qbt_api_response_parse_error, endpoint]
        blk.call(nil)
      end
      end
    end
  end
end
