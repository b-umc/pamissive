# frozen_string_literal: true

require 'json'
require 'uri'
require_relative '../../nonblock_HTTP/manager'

class QbtClient
  API_ENDPOINT = 'https://rest.tsheets.com/api/v1'

  def initialize(auth_token_provider = nil)
    @token_provider = auth_token_provider
  end

  def timesheets_modified_since(timestamp_iso, after_id: nil, limit: 50, order: :asc, supplemental: false, &blk)
    params = {
      modified_since: timestamp_iso,
      limit: limit,
      sort_order: order,
      supplemental_data: supplemental ? 'yes' : 'no'
    }
    params[:after_id] = after_id if after_id
    api_request("timesheets?#{URI.encode_www_form(params)}", &blk)
  end

  def users(page:, limit:, &blk)
    params = { page: page, per_page: limit }
    api_request("users?#{URI.encode_www_form(params)}", &blk)
  end

  def jobcodes(page:, limit:, &blk)
    params = { page: page, per_page: limit }
    api_request("jobcodes?#{URI.encode_www_form(params)}", &blk)
  end

  private

  def api_request(endpoint, &blk)
    token = @token_provider&.call
    return blk.call(nil) unless token

    headers = { 'Authorization' => "Bearer #{token}" }
    url = "#{API_ENDPOINT}/#{endpoint}"

    NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }, log_debug: true) do |response|
      next blk.call(nil) unless response

      if response.code == 404 && endpoint.start_with?('timesheets')
        return blk.call({ 'timesheets' => [], 'more' => false })
      end

      next blk.call(nil) unless response.code == 200

      begin
        blk.call(JSON.parse(response.body))
      rescue JSON::ParserError
        blk.call(nil)
      end
    end
  end
end
