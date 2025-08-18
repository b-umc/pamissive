# frozen_string_literal: true

require 'json'
require 'digest'
require 'pg'
require 'envkey'
require 'time'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
LOG.debug('Starting DTools API client fetcher')
require_relative '../../nonblock_HTTP/manager'
require_relative '../../database/pg/pg_non_block'
require_relative 'objects'
require_relative 'events'

class DTools
  include Objects
  include TimeoutInterface

  attr_reader :database

  API_KEY = ENV.fetch('DTOOLS_API_KEY', nil)
  API_BEARER = ENV.fetch('DTOOLS_API_BEARER', nil)
  API_URL = 'https://dtcloudapi.d-tools.cloud/api/v1'
  CLIENTS_PATH = "#{API_URL}/Clients"
  CALLBACK_EVENT_PATH = '/dtools/callback'
  CALLBACK_EVENT_TOKEN = ENV.fetch('DTOOLS_EVENT_TOKEN', nil)
  RESYNC_INTERVAL_SECONDS = 60 * 5

  HEADERS = {
    'Authorization' => "Basic #{API_BEARER}",
    'X-API-Key' => API_KEY,
    'Connection' => 'keep-alive',
    'Keep-Alive' => 'timeout=10, max=100'
  }.freeze

  def initialize(database)
    @database = database
    @http_server = NonBlockHTTP::Manager.server(port: 8080)
    @objects = {
      opportunities: {}, clients: {}, products: {}, projects: {},
      purchase_orders: {}, service_contracts: {}, quotes: {}
    }
    @http_server.on(
      CALLBACK_EVENT_PATH, method(:handle_dtools_event)
    )
    # load_endpoints { sync_timer }
  end

  def close_database
    @database.close
  end

  def dtools_get(endpoint, retries = 3, delay = 60, &block)
    endpoint = "#{API_URL}/#{endpoint}" unless endpoint.include?('http')

    NonBlockHTTP::Client::ClientSession.new.get(endpoint, { headers: HEADERS }) do |response|
      case response.code
      when 200 then block.call(response) if block_given?
      when 429 then handle_dtools_rate_limit(endpoint, retries, delay, &block)
      else LOG.error([:dtools_get_error, response])
      end
    end
  end

  private

  def load_endpoints(index = 0, &block)
    endpoint = Objects::PAGINATED[index]
    LOG.debug([:synconizing, endpoint])
    return block.call unless endpoint

    load_endpoint_data(endpoint) do |data|
      data.each do |dat|
        @objects[endpoint][dat['id']] = dat

      end
      LOG.debug([:loaded_data_from_db, endpoint, @objects[endpoint]])
      load_endpoints(index + 1, &block)
    end
  end

  def load_endpoint_data(endpoint, &block)
    sql = "SELECT * FROM dtools_#{endpoint}"
    @database.exec(sql) do |result|
      block.call(result)
    end
  end

  def sync_timer
    sync_endpoints do
      LOG.debug(%i[dtools_init_sync_complete])
      add_timeout(method(:sync_timer), RESYNC_INTERVAL_SECONDS)
    end
  end

  def sync_timer_old
    sync_endpoints do
      LOG.debug(%i[dtools_init_sync_complete syncing_quotes])
      sync_quotes do
        LOG.debug(%i[dtools_quote_sync_complete storing_quotes])
        sync_pages_to_db(:quotes, @objects[:quotes].values) do |result|
          LOG.debug([:dtools_quotes_store_complete, result])
          add_timeout(method(:sync_timer), RESYNC_INTERVAL_SECONDS)
        end
      end
    end
  end

  def sync_quotes(opportunity_idx = 0, &block)
    return block.call unless (opportunity = @objects[:opportunities].values[opportunity_idx])

    fetch_page(:quotes, opportunityId: opportunity['id']) do |result|
      LOG.debug([:quotes_for_opportunity, opportunity['id'], :sync_result, result])
      process_quotes_for_opportunity(result, opportunity)
      sync_quotes(opportunity_idx + 1, &block)
    end
  end

  def process_quotes_for_opportunity(quotes, opportunity)
    data = JSON.parse(quotes.body)
    data.each do |quote|
      LOG.debug([:row, quote])
      quote['opportunity_id'] = opportunity['id']
      @objects[:quotes][quote['id']] = quote
    end
  end

  def sync_endpoints(index = 0, &block)
    endpoint = Objects::PAGINATED[index]
    LOG.debug([:synconizing, endpoint])
    return block.call unless endpoint

    sync_endpoint(endpoint) do |result|
      LOG.debug([endpoint, :sync_result, result])

      sync_endpoints(index + 1, &block)
    end
  end

  def sync_endpoint(endpoint, &block)
    fetch_last_endpoint_sync(endpoint) do |since|
      fetch_and_store_endpoint(endpoint, since) do |res|
        LOG.debug([endpoint, :sync_timestamp_update_result, res])
        block.call(res)
      end
    end
  end

  def fetch_last_endpoint_sync(endpoint, &block)
    sql = 'SELECT last_successful_sync FROM api_sync_logs WHERE api_name = $1'
    @database.exec_params(sql, ["dtools_#{endpoint}"]) do |result|
      block.call(handle_last_sync_query(result))
    end
  end

  def fetch_and_store_endpoint(endpoint, since = nil, &block)
    fetch_all_objects_for_endpoint(endpoint, since) do |objects|
      sync_pages_to_db(endpoint, objects) do |res|
        LOG.debug([endpoint, :sync_result, res])
        update_sync_success(endpoint) do |result|
          block.call(result)
        end
      end
    end
  end

  def fetch_all_objects_for_endpoint(endpoint, since = nil, &block)
    fetch_pages(endpoint, {}, since: since) do |objects|
      LOG.debug([:dtools__response_record_count_for, endpoint, objects.length])
      block.call(objects)
    end
  end

  def update_sync_success(endpoint, &block)
    sql = %{
          INSERT INTO api_sync_logs (api_name, last_successful_sync)
          VALUES ($1, $2)
          ON CONFLICT (api_name)
          DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
        }
    DB.exec_params(sql, ["dtools_#{endpoint}", Time.now.utc.iso8601]) do |result|
      LOG.debug("Sync log update for dtools_#{endpoint} result. #{result}")
      block.call
    end
  end

  def delete_endpoint_row(endpoint, uuid, &block)
    sql = %(
      DELETE FROM dtools_#{endpoint}
      WHERE id = '#{uuid}'
    )
    DB.exec(sql) do |result|
      LOG.debug("Row delete from dtools_#{endpoint} result. #{result}")
      block&.call
    end
  end

  def handle_last_sync_query(result)
    return nil unless result.ntuples&.positive?

    # utc_sync_time = result[0]['last_successful_sync']
    # Time.parse(utc_sync_time)
    t = result[0]['last_successful_sync']
    "#{t.split.join('T')}.00Z"
  end

  def sync_pages_to_db(endpoint, hash_map, &block)
    LOG.debug([:dtools_insert, endpoint, hash_map&.first&.keys])
    return block.call(0) if hash_map.nil? || hash_map.empty?

    values_list = hash_map.map do |hash|
      Objects::ENDPOINT_TABLE_KEYS[endpoint].map { |key| DB.format_value(hash[key]) }.join(', ')
    end

    query = %(
      INSERT INTO dtools_#{endpoint} (#{Objects::ENDPOINT_TABLE_COLUMNS[endpoint].join(', ')})
      VALUES
        #{values_list.map { |values| "(#{values})" }.join(",\n        ")}
      ON CONFLICT (id) DO UPDATE SET#{Objects::ENDPOINT_CONFLICTS[endpoint]}
    )

    LOG.debug("Constructed SQL Query: #{query}")

    # Execute the query
    DB.exec(query) do |result|
      block.call(result)
    end
  end

  def store_object_for_endpoint(endpoint, hash, &block)

    values = Objects::ENDPOINT_TABLE_KEYS[endpoint].map { |key| DB.format_value(hash[key]) }.join(', ')
    query = %(
      INSERT INTO dtools_#{endpoint} (#{Objects::ENDPOINT_TABLE_COLUMNS[endpoint].join(', ')})
      VALUES (#{values})
      ON CONFLICT (id) DO UPDATE SET#{Objects::ENDPOINT_CONFLICTS[endpoint]}
    )

    LOG.debug("Constructed SQL Query: #{query}")

    # Execute the query
    DB.exec(query) do |result|
      block.call(result)
    end
  end

  def fetch_object_for_endpoint(endpoint, object_id, &block)
    url_path = [
      Objects::PATHS[endpoint],
      url_parameters(Objects::ENDPOINT_QUERY_KEYWORDS[endpoint], id: object_id)
    ]
    LOG.debug([:requesting, url_path])
    dtools_get(url_path.join, &block)
  end

  def fetch_page(endpoint, **kwargs, &block)
    url_path = [
      Objects::PATHS[endpoint],
      url_parameters(Objects::ENDPOINT_QUERY_KEYWORDS[endpoint], **kwargs)
    ]
    LOG.debug([:requesting, url_path])
    dtools_get(url_path.join, &block)
  end

  def fetch_pages(endpoint, pages = {}, page_num = 1, page_size = 500, since: nil, &block)
    fetch_page(endpoint, page: page_num, pageSize: page_size, fromModifiedDate: since) do |response|
      pages, complete = process_page(endpoint, response, page_size, pages)
      LOG.debug([object_id, :page_fetched, :obtained_total, pages.length, complete, page_num])
      if complete
        block.call(pages.values)
      else
        fetch_pages(endpoint, pages, page_num + 1, page_size, since: since, &block)
      end
    end
  end

  def process_page(endpoint, page, page_size, pages)
    dat = JSON.parse(page.body)
    t = Time.now.utc.iso8601
    objects = dat[Objects::ENDPOINT_CONTAINERS[endpoint]]
    objects.each do |e|
      LOG.debug([:row, e])
      return [pages, true] if pages[e['id']]

      e['last_sync_time'] = t
      @objects[endpoint][e['id']] = e
      pages[e['id']] = e
    end
    [pages, page_size != objects.length]
    # [pages, true]
  end

  def dtools_sync
    client_sync
    add_timeout(method(:dtools_sync), RESYNC_INTERVAL_SECONDS)
  end

  def setup_database_statements
    @database.prepare('update_insert_client', update_insert_client_statement)
    @database.prepare('update_insert_client_billing_address', update_insert_client_billing_address)
    @database.prepare('update_insert_client_site_address', update_insert_client_site_address)
    @database.prepare('update_insert_client_contact', update_insert_client_contact)
    @database.prepare('update_insert_client_files', update_insert_client_files)
    @database.prepare('update_insert_client_contacts_map', update_insert_client_contacts_map)
  end

  def handle_dtools_rate_limit(endpoint, retries, delay, &block)
    LOG.debug([:rate_limited, retries, delay, :continue?, retries.positive?])
    return unless retries.positive?

    add_timeout(proc { dtools_get(endpoint, retries - 1, delay.pow(2), &block) }, delay)
  end

  def url_parameters(keywords, **kwargs)
    param_array = []
    keywords.each do |keyword|
      param_array << "#{keyword}=#{kwargs[keyword]}" if kwargs[keyword]
    end

    param_array.empty? ? '' : "?#{param_array.join('&')}"
  end

  def db_run_prepared_request(stmt_name:, values:, &block)
    LOG.debug([:db_run_prepared_request, stmt_name, values])
    @database.exec_prepared(stmt_name, values, &block)
  rescue PG::Error => e
    LOG.error([:database_error, e, e.backtrace])
    exit
  end

  def handle_dtools_event(request, response, &block)
    response.status = 200
    response.close
    block.call(response)
    headers = request.headers
    request_data = request.body
    return unless valid_token?(headers['api-token'])
    return unless (data = handle_request_data(request_data))
    return unless supported_event?(data['Event'])

    send(data['Event'], data)
  end

  def supported_event?(event)
    LOG.debug([:dtools_responds_to, event, respond_to?(event)])
    return true if respond_to?(event)

    LOG.error("Unsupported Event Encountered #{event}")
    false
  end

  def handle_request_data(data)
    dat = JSON.parse(data)
    EventBus.publish('dtools', dat['Event'], dat)
    dat
  rescue JSON::ParserError => e
    LOG.error([:error_parsing_json_data, e, e.backtrace, data])
    nil
  end

  def valid_token?(token)
    return true if token == CALLBACK_EVENT_TOKEN

    LOG.error('Invalid API Token in dtools event')
    false
  end
end

unless defined?(DB)
  DB = PGNonBlock.new(
    {
      dbname: 'ruby_jobsites',
      user: ENV.fetch('PG_JOBSITES_UN', nil),
      password: ENV.fetch('PG_JOBSITES_PW', nil),
      host: 'localhost'
    }
  )

  at_exit { DB.close }
end

DTOOLS = DTools.new(DB) unless defined? DTOOLS
