# frozen_string_literal: true

module DTools::Client; end
module DTools::Client::PG; end

module DTools::Client::PG::PGCreate
  CREATE_TABLE_COMMANDS = {
    'dtools_client_details' => %{
          CREATE TABLE IF NOT EXISTS dtools_client_details (
            id UUID PRIMARY KEY,
            type CHARACTER VARYING,
            name CHARACTER VARYING,
            number CHARACTER VARYING,
            email CHARACTER VARYING,
            secondary_email CHARACTER VARYING,
            phone CHARACTER VARYING,
            fax CHARACTER VARYING,
            website CHARACTER VARYING,
            owner CHARACTER VARYING,
            created_date TIMESTAMP WITH TIME ZONE,
            modified_date TIMESTAMP WITH TIME ZONE,
            is_active BOOLEAN,
            details_last_retrieved TIMESTAMP WITH TIME ZONE
          )
        },
    'dtools_client_billing_addresses' => %{
          CREATE TABLE IF NOT EXISTS dtools_client_billing_addresses (
            client_id UUID NOT NULL,
            name CHARACTER VARYING,
            address_line1 CHARACTER VARYING,
            address_line2 CHARACTER VARYING,
            city CHARACTER VARYING,
            state CHARACTER VARYING,
            postal_code CHARACTER VARYING,
            country CHARACTER VARYING,
            address_hash TEXT
          )
        },
    'dtools_contacts' => %{
          CREATE TABLE IF NOT EXISTS dtools_contacts (
            id UUID PRIMARY KEY,
            name CHARACTER VARYING,
            first_name CHARACTER VARYING,
            last_name CHARACTER VARYING,
            company CHARACTER VARYING,
            title CHARACTER VARYING,
            email CHARACTER VARYING,
            secondary_email CHARACTER VARYING,
            mobile CHARACTER VARYING,
            phone CHARACTER VARYING,
            fax CHARACTER VARYING,
            address_line1 CHARACTER VARYING,
            address_line2 CHARACTER VARYING,
            city CHARACTER VARYING,
            state CHARACTER VARYING,
            postal_code CHARACTER VARYING,
            country CHARACTER VARYING,
            notes TEXT,
            is_active BOOLEAN,
            is_primary BOOLEAN
          )
        },
    'dtools_client_contacts_map' => %{
          CREATE TABLE IF NOT EXISTS dtools_client_contacts_map (
            client_id UUID NOT NULL,
            contact_id UUID NOT NULL
          )
        },
    'dtools_client_files' => %{
          CREATE TABLE IF NOT EXISTS dtools_client_files (
            file_id SERIAL PRIMARY KEY,
            client_id UUID NOT NULL,
            name TEXT,
            url TEXT
          )
        },
    'dtools_client_site_addresses' => %{
          CREATE TABLE IF NOT EXISTS dtools_client_site_addresses (
            client_id UUID NOT NULL,
            name TEXT,
            address_line1 TEXT,
            address_line2 TEXT,
            city TEXT,
            state TEXT,
            postal_code TEXT,
            country TEXT,
            address_hash TEXT NOT NULL
          )
        },
    'api_sync_logs' => %{
          CREATE TABLE IF NOT EXISTS api_sync_logs (
            id SERIAL PRIMARY KEY,
            api_name CHARACTER VARYING NOT NULL,
            last_successful_sync TIMESTAMP WITH TIME ZONE
          )
        },
    'api_sync_logs_constraint' => %{
          ALTER TABLE api_sync_logs
          ADD CONSTRAINT api_name_unique UNIQUE (api_name);
        }
  }.freeze
end
