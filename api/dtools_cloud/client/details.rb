# frozen_string_literal: true

require 'time'

module DTools::Client::Details
  include PG
  include Parsing

  SYNC_API_KEY = 'api_dtools_clients'

  SYNC_TIME_UPDATE = <<~SQL
    INSERT INTO api_sync_logs (api_name, last_successful_sync)
    VALUES ($1, $2)
    ON CONFLICT (api_name) DO UPDATE
    SET last_successful_sync = EXCLUDED.last_successful_sync;
  SQL

  GET_CLIENTS_KEYWORDS = %i[
    types owners fromCreatedDate toCreatedDate
    fromModifiedDate toModifiedDate includeInactive
    includeTotalCount search sort page pageSize
  ].freeze

  def client_sync
    sql = 'SELECT last_successful_sync FROM api_sync_logs WHERE api_name = $1'
    @database.exec_params(sql, [SYNC_API_KEY]) do |result|
      sync_time = handle_last_sync_query(result)
      fetch_all_clients(since: sync_time)
    end
  end

  def fetch_all_clients(page = 1, page_size = 20, since: nil)
    @client_updates = [] if page == 1
    fetch_clients(page: page, pageSize: page_size, fromModifiedDate: since) do |response|
      clients_data = JSON.parse(response.body)['clients']
      @client_updates += clients_data
      handle_fetched_clients(clients_data.length, page, page_size, since)
    end
  end

  def fetch_client_details(id, &block)
    url_path = [
      DTools::CLIENTS_PATH,
      '/GetClient',
      url_parameters([:id], id: id)
    ]
    dtools_get(url_path.join, &block)
  end

  def fetch_clients(**kwargs, &block)
    url_path = [
      DTools::CLIENTS_PATH,
      '/GetClients',
      url_parameters(GET_CLIENTS_KEYWORDS, **kwargs)
    ]
    dtools_get(url_path.join, &block)
  end

  private

  def handle_last_sync_query(result)
    return nil unless result.ntuples&.positive?

    utc_sync_time = result[0]['last_successful_sync']
    local_sync_time = Time.parse(utc_sync_time).utc.iso8601
    LOG.debug([:last_sync_time, local_sync_time])
    local_sync_time
    # Time.parse(last_sync_str)
  end

  def handle_fetched_clients(clients_size, page, page_size, since)
    return fetch_client_updates(since) unless clients_size == page_size

    fetch_all_clients(page + 1, page_size, since: since)
  end

  def fetch_client_updates(since = nil)
    return update_api_sync if @client_updates.empty?

    client = @client_updates.shift
    tsince = Time.parse(since)
    tmod = Time.parse("#{client['modifiedDate']}Z")
    return fetch_client_updates(since) unless tmod > tsince

    fetch_client_details(client['id']) do |response, _|
      process_client_details(JSON.parse(response.body))
      fetch_client_updates(since)
    end
  end

  def update_api_sync
    t = Time.now.getutc
    LOG.debug(['dtools client sync updated.', t])
    @database.exec_params(SYNC_TIME_UPDATE, [SYNC_API_KEY, t]) do |result|
      LOG.error("Database Error: #{result.error_message}") unless result.error_message.empty?
    end
  end
end
