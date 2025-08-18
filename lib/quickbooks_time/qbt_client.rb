# frozen_string_literal: true

require 'json'
require 'uri'

class QbtClient
  API_ENDPOINT = 'https://rest.tsheets.com/api/v1'

  def initialize(_auth_token_provider = nil)
  end

  def timesheets_modified_since(timestamp_iso, after_id: nil, limit: 50, order: :asc, supplemental: false)
    params = {
      modified_since: timestamp_iso,
      limit: limit,
      sort_order: order,
      supplemental_data: supplemental ? 'yes' : 'no'
    }
    params[:after_id] = after_id if after_id
    api_request("timesheets?#{URI.encode_www_form(params)}")
  end

  def users(page:, limit:)
    params = { page: page, per_page: limit }
    api_request("users?#{URI.encode_www_form(params)}")
  end

  def jobcodes(page:, limit:)
    params = { page: page, per_page: limit }
    api_request("jobcodes?#{URI.encode_www_form(params)}")
  end

  private

  def api_request(_endpoint)
    {} # placeholder for HTTP request
  end
end
