# frozen_string_literal: true

require 'json'
require 'date'
require 'time'
require 'uri'
require_relative '../../nonblock_HTTP/client/session'
require_relative 'rate_limiter'
require_relative 'util/constants'
require_relative '../shared/dt'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class QbtClient
  API_ENDPOINT = 'https://rest.tsheets.com/api/v1'

  def initialize(auth_token_provider = nil, limiter: RateLimiter.new(interval: Constants::QBT_RATE_INTERVAL))
    @token_provider = auth_token_provider
    @limiter = limiter
  end

  def timesheets_modified_since(timestamp_iso, page: 1, limit: 50, supplemental: true, &blk)
    # Compute a robust modified_since in UTC, subtracting a small skew to avoid
    # missing rows that share the same second as the last sync.
    base = Shared::DT.parse_utc(timestamp_iso, source: :qbt_input_time) || Time.now.utc
    ms = (base - Constants::QBT_SINCE_SKEW_SEC).iso8601
    LOG.debug [:qbt_input_time, timestamp_iso, :to, :internal_time, base.iso8601]

    # Use a deterministic start_date for backfills so that older-dated
    # timesheets are included from a stable epoch. Allow disabling.
    params = {
      modified_since: ms,
      limit: limit,
      page: page,
      on_the_clock: 'both'
    }
    unless Constants::QBT_DISABLE_START_DATE_WITH_SINCE
      params[:start_date] = Constants::BACKFILL_EPOCH_DATE.to_s
    end
    params[:supplemental_data] = supplemental ? 'yes' : 'no'
    LOG.debug [:qbt_timesheets_params, params]
    api_request("timesheets?#{URI.encode_www_form(params)}", &blk)
  end

  # Fetch timesheets within a date range (inclusive). Useful to detect
  # in-progress timesheets that may not surface via modified_since yet.
  def timesheets_by_date(start_date:, end_date:, page: 1, limit: 50, supplemental: true, &blk)
    params = {
      start_date: start_date,
      end_date: end_date,
      limit: limit,
      page: page,
      on_the_clock: 'both'
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

  # Fetch last_modified_timestamps for all primary entities
  def last_modified_timestamps(&blk)
    api_request('last_modified_timestamps', &blk)
  end

  # Fetch timesheets deleted since timestamp. QBT returns rows with at least
  # id and a deletion timestamp (e.g., 'deleted' or 'last_modified').
  def timesheets_deleted_modified_since(timestamp_iso, page: 1, limit: 50, &blk)
    params = { modified_since: timestamp_iso, page: page, per_page: limit }
    api_request("timesheets_deleted?#{URI.encode_www_form(params)}", &blk)
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

      if response.code == 404
        if endpoint.start_with?('timesheets_deleted')
          blk.call({ 'results' => { 'timesheets_deleted' => {} }, 'more' => false })
          next
        elsif endpoint.start_with?('timesheets')
          blk.call({ 'results' => { 'timesheets' => {} }, 'more' => false })
          next
        end
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
