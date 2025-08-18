# frozen_string_literal: true

require_relative 'pg_create'

module DTools::Client::PG
  include PGCreate

  CLIENT_KEYS = %w[
    id type name number email secondary_email
    phone fax website owner created_date
    modified_date is_active details_last_retrieved
  ].freeze

  ADDRESS_KEYS = %w[
    client_id name address_line1 address_line2
    city state postal_code country address_hash
  ].freeze

  CONTACTS_KEYS = %w[
    id first_name last_name company title email
    secondary_email mobile phone fax address_line1
    address_line2 city state postal_code country
    notes is_active is_primary
  ].freeze

  FILES_KEYS = %w[
    client_id name url
  ].freeze

  CONACTS_KEYS = %w[
    client_id contact_id
  ].freeze

  def update_insert_statement(table_name, db_keys, conflict_key)
    db_set = db_keys.map { |col| "#{col} = EXCLUDED.#{col}" }.join(', ')
    db_place = db_keys.length.times.map { |i| "$#{i + 1}" }.join(', ')
    db_cols = db_keys.join(', ')
    <<-SQL
      INSERT INTO #{table_name} (#{db_cols})
      VALUES (#{db_place})
      ON CONFLICT (#{conflict_key}) DO UPDATE SET #{db_set}
    SQL
  end

  def update_insert_client_statement
    update_insert_statement('dtools_client_details', CLIENT_KEYS, 'id')
  end

  def update_insert_client_billing_address
    update_insert_statement('dtools_client_billing_addresses', ADDRESS_KEYS, 'client_id')
  end

  def update_insert_client_site_address
    update_insert_statement('dtools_client_site_addresses', ADDRESS_KEYS, 'address_hash')
  end

  def update_insert_client_contact
    update_insert_statement('dtools_contacts', CONTACTS_KEYS, 'id')
  end

  def update_insert_client_files
    update_insert_statement('dtools_client_files', FILES_KEYS, 'url')
  end

  def update_insert_client_contacts_map
    db_place = CONACTS_KEYS.length.times.map { |i| "$#{i + 1}" }.join(', ')
    db_cols = CONACTS_KEYS.join(', ')
    <<-SQL
      INSERT INTO dtools_client_contacts_map (#{db_cols})
      VALUES (#{db_place})
      ON CONFLICT (client_id, contact_id) DO NOTHING
    SQL
  end

  def update_sync_success(conn)
    sql = %{
          INSERT INTO api_sync_logs (api_name, last_successful_sync)
          VALUES ($1, $2)
          ON CONFLICT (api_name)
          DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
        }
    conn.exec_params(sql, [api_name, timestamp])
    LOG.debug("Sync log updated for #{api_name}.")
  end

  def process_array(arr, &block)
    return if arr.empty?

    block.call(arr.first) do
      process_array(arr[1..], &block)
    end
  end

  def create_client_tables(conn)
    process_array(CREATE_TABLE_COMMANDS.values) do |sql|
      conn.exec(sql)
    end
  end
end
