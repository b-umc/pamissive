# frozen_string_literal: true

class DTools; end
module DTools::Client; end
module DTools::Client::Details; end

module DTools::Client::Details::Parsing
  CLIENT_KEYS = %w[
    id type name number email secondaryEmail phone fax
    website owner createdDate modifiedDate isActive
  ].freeze

  ADDRESS_KEYS = %w[
    name addressLine1 addressLine2
    city state postalCode country
  ].freeze

  CONTACTS_KEYS = %w[
    id firstName lastName company title email
    secondaryEmail mobile phone fax addressLine1
    addressLine2 city state postalCode country
    notes isActive isPrimary
  ].freeze

  FILES_KEYS = %w[
    client_id name url
  ].freeze

  def process_client_details(client_data)
    LOG.debug([:client_details, client_data])
    process_client_data(client_data)
    process_client_site_addresses(client_data['id'], client_data['siteAddresses'] || [])
    process_client_billing_address(client_data['id'], client_data['billingAddress'] || {})
    process_client_files(client_data['id'], client_data['files'] || [])
    process_client_contacts(client_data['id'], client_data['contacts'] || [])
  end

  def process_client_data(client_data)
    client_data['modifiedDate'] << 'Z'
    client_data['createdDate'] << 'Z'
    values = CLIENT_KEYS.map { |key| client_data[key] } << Time.now
    db_run_prepared_request(stmt_name: 'update_insert_client', values: values)
  end

  def process_client_site_addresses(client_id, site_addresses)
    return if site_addresses.empty?

    LOG.debug([:client_site_addresses, client_id, site_addresses])
    site_addresses.each do |site_address|
      address_hash = Digest::SHA256.hexdigest(site_address.values.join('|'))
      values = ADDRESS_KEYS.map { |key| site_address[key] }.unshift(client_id) << address_hash
      db_run_prepared_request(stmt_name: 'update_insert_client_site_address', values: values)
    end
  end

  def process_client_billing_address(client_id, billing_address)
    return if billing_address.empty?

    LOG.debug([:client_billing_address, client_id, billing_address])
    address_hash = Digest::SHA256.hexdigest(billing_address.values.join('|'))
    values = ADDRESS_KEYS.map { |key| billing_address[key] }.unshift(client_id) << address_hash
    db_run_prepared_request(stmt_name: 'update_insert_client_billing_address', values: values)
  end

  def process_client_files(client_id, files)
    return if files.empty?

    LOG.debug([:client_files, client_id, files])
    files.each do |file|
      values = FILES_KEYS.map { |key| file[key] }.unshift(client_id)
      db_run_prepared_request(stmt_name: 'update_insert_client_files', values: values)
    end
  end

  def process_client_contacts(client_id, contacts)
    return if contacts.empty?

    LOG.debug([:client_contacts, client_id, contacts])
    contacts.each do |contact|
      values = CONTACTS_KEYS.map { |key| contact[key] }
      db_run_prepared_request(stmt_name: 'update_insert_client_contact', values: values)
      db_run_prepared_request(stmt_name: 'update_insert_client_contacts_map', values: [client_id, contact['id']])
    end
  end
end
