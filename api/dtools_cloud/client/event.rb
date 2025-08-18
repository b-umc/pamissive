# frozen_string_literal: true

module DTools::Client::Event
  def client_updated(data)
    fetch_client_details(data['ObjectId']) do |reply|
      process_client_details(JSON.parse(reply.body))
    end
  end
end
