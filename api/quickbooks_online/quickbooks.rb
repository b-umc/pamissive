# frozen_string_literal: true

require 'json'
require 'uri'
require 'openssl'
require 'base64'
require 'envkey'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'auth_server'
require_relative '../../nonblock_HTTP/manager'

class Quickbooks
  API_ENDPOINT = 'https://quickbooks.api.intuit.com/v3/company'
  API_NAME = 'quickbooks'

  def initialize(port: 8080)
    @server = NonBlockHTTP::Manager.server(port: port)
    @authorized = false
    @auth = AuthServer.new(@server)
    EventBus.subscribe('quickbooks_auth', 'authorization', method(:qbo_state))
    @server.on('/quickbooks/event', method(:on_event))
  end

  def status
    @auth.status
  end

  def auth_url
    @auth.auth_url
  end

  def initial_sync_customers
    get_last_sync_time(API_NAME) do |last_sync_time|
      if last_sync_time
        sync_customers_since(last_sync_time)
      else
        sync_all_customers
      end
    end
  end

  def search_customers(query, &block)
    sql = %{
      SELECT c.*, a.*
      FROM qb_customers c
      LEFT JOIN qb_addresses a ON c.id = a.customer_id
      WHERE c.display_name % $1
        OR c.email % $1
        OR c.phone % $1
        OR a.line1 % $1
      ORDER BY
        GREATEST(
          similarity(c.display_name, $1),
          similarity(c.email, $1),
          similarity(c.phone, $1),
          similarity(a.line1, $1)
        )
    }

    DB.exec_params(sql, [query]) do |result|
      block.call(result.to_a)
    end
  end

  def get_last_sync_time(api_name, &block)
    DB.exec_params('SELECT last_successful_sync FROM api_sync_logs WHERE api_name = $1', [api_name]) do |result|
      block.call(result.ntuples.zero? ? nil : result[0]['last_successful_sync'])
    end
  end

  def sync_customer_to_db(customer)
    customer_id = SecureRandom.uuid
    address = customer['BillAddr']

    DB.exec_params(
      'INSERT INTO qb_customers (id, qb_id, display_name, email, phone, line1, city, postal_code, created_date, modified_date, is_active)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), NOW(), $9)
       ON CONFLICT (qb_id) DO UPDATE
       SET display_name = EXCLUDED.display_name,
           email = EXCLUDED.email,
           phone = EXCLUDED.phone,
           line1 = EXCLUDED.line1,
           city = EXCLUDED.city,
           postal_code = EXCLUDED.postal_code,
           modified_date = NOW(),
           is_active = EXCLUDED.is_active',
      [
        customer_id,
        customer['Id'],
        customer['DisplayName'],
        customer['PrimaryEmailAddr']&.fetch('Address', nil),
        customer['PrimaryPhone']&.fetch('FreeFormNumber', nil),
        address&.fetch('Line1', nil),
        address&.fetch('City', nil),
        address&.fetch('PostalCode', nil),
        customer['Active']
      ]
    ) do |result|
      sync_address_to_db(customer_id, address) if address
      LOG.debug("Synced customer with ID #{customer['Id']} to the database")
    end
  end

  def sync_address_to_db(customer_id, address)
    DB.exec_params(
      'INSERT INTO qb_addresses (customer_id, line1, city, postal_code, address_hash)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (customer_id) DO UPDATE
       SET line1 = EXCLUDED.line1,
           city = EXCLUDED.city,
           postal_code = EXCLUDED.postal_code,
           address_hash = EXCLUDED.address_hash',
      [
        customer_id,
        address['Line1'],
        address['City'],
        address['PostalCode'],
        Digest::SHA256.hexdigest(address.to_s)
      ]
    ) do |result|
      LOG.debug("Synced address for customer with ID #{customer_id} to the database")
    end
  end

  def on_event(req, res)
    digest = OpenSSL::Digest.new('sha256')
    hmac = OpenSSL::HMAC.digest(digest, ENV.fetch('QBO_EVENT_TOKEN', nil), req.body)
    hash = Base64.strict_encode64(hmac)
    handle_event(req.body) if hash == req['intuit-signature']
    res.status = 200
    res.close
  end

  def handle_event(body)
    data = JSON.parse(body)
    LOG.debug([:qb_event, data])
    event_type = data['eventNotifications'][0]['eventType']
    entity = data['eventNotifications'][0]['dataChangeEvent']['entities'][0]
    entity_type = entity['name']
    entity_id = entity['id']
    handle_event_entity(event_type, entity_id, entity_type)
  end

  def handle_event_entity(verb, id, type)
    EventBus.publish('quickbooks_online', verb, { id: id, type: type })
    return unless type == 'Customer'

    case verb
    when 'Create', 'Update'
      fetch_and_store_customer(id)
    when 'Delete'
      delete_customer(id)
    end
  end

  def fetch_and_store_customer(customer_id)
    api_request("customer/#{customer_id}") do |response|
      customer = response['Customer']
      sync_customer_to_db(customer)
    end
  end

  def delete_customer(customer_id)
    DB.exec_params('DELETE FROM qb_customers WHERE qb_id = $1', [customer_id])
    LOG.debug("Deleted customer with ID #{customer_id} from the database")
  end

  def api_request(endpoint, query_params = {}, &block)
    query_string = URI.encode_www_form(query_params)
    url = "#{API_ENDPOINT}/#{@auth.realm_id}/#{endpoint}?#{query_string}"
    headers = { 'Authorization' => "Bearer #{@auth.token.access_token}", 'accept' => 'application/json' }
    NonBlockHTTP::Client::ClientSession
      .new
      .get(url, { headers: headers }) { |response| handle_api_response(response, &block) }
  end

  def handle_api_response(response)
    raise "QuickBooks API Error: #{response.code} - #{response.inspect}" unless response.code == 200

    r = response.body
    LOG.debug(r)
    yield JSON.parse(r)
  end

  def sync_customers_since(last_sync_time, start_position = 1)
    formatted_time = Time.parse(last_sync_time).utc.iso8601
    api_request('query', { query: "SELECT * FROM Customer WHERE MetaData.LastUpdatedTime > '#{formatted_time}' ORDERBY Id STARTPOSITION #{start_position} MAXRESULTS 1000" }) do |response|
      customers = response['QueryResponse']['Customer'] || []
      customers.each { |customer| sync_customer_to_db(customer) }
      if customers.size == 1000
        sync_customers_since(last_sync_time, start_position + 1000)
      else
        update_sync_success(API_NAME, Time.now)
      end
    end
  end

  def update_sync_success(api_name, timestamp)
    sql = %{
          INSERT INTO api_sync_logs (api_name, last_successful_sync)
          VALUES ($1, $2)
          ON CONFLICT (api_name)
          DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
        }
    DB.exec_params(sql, [api_name, timestamp]) do |result|
      LOG.debug("Sync log update for #{api_name} result. #{result}")
    end
  end

  def qbo_state(*args)
    state = args.flatten.first[:authorized] == true
    return if @authorized == state

    @authorized = state
    initial_sync_customers if state == true
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

QBO = Quickbooks.new unless defined?(QBO)
