# frozen_string_literal: true

class QuickbooksTime
  class QbtClient
    API_ENDPOINT = 'https://rest.tsheets.com/api/v1'

    def initialize(auth_token_provider)
      @auth = auth_token_provider
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
    
    # Add other methods for users, jobcodes etc. as needed

    private

    def api_request(endpoint, &callback)
      headers = { 'Authorization' => "Bearer #{@auth.token.access_token}" }
      url = "#{API_ENDPOINT}/#{endpoint}"

      NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }, log_debug: true) do |response|
        raise "QBT API Error: #{response.code} #{response.body}" unless (200..299).include?(response.code)
        
        begin
          parsed_body = JSON.parse(response.body)
          callback.call(parsed_body)
        rescue JSON::ParserError => e
          LOG.error "Failed to parse JSON response from #{endpoint}. Body: #{response.body.inspect}"
          callback.call({}) # Return empty on parse error
        end
      end
    end
  end
end
