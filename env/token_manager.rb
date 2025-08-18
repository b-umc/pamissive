# frozen_string_literal: true

require 'envkey'
require 'time'
require 'json'
require 'jwt'
require_relative '../database/pg/pg_non_block'
require_relative 'encryptor'

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

class AuthToken
  attr_accessor :iv, :extra_data, :expires_at
  attr_reader :data, :refresh_token, :access_token, :service, :user_info

  def initialize(service, data = {})
    @user_info = {}
    @data = {}
    @expires_in = nil
    @expires_at = nil
    @iv = nil
    @service = service
    @extra_data = {}
    @access_token = nil
    @refresh_token = nil
    update_data(data)
    # LOG.debug([:loaded_token, @data])
  end

  def data=(data_hash = {})
    update_data(data_hash)
  end

  def expires_in
    return 0 unless @expires_at.is_a?(Time)

    @expires_at - Time.now
  end

  def expires_in=(expiry_seconds)
    update_expiry(expiry_seconds)
  end

  def to_json(*_args)
    @data.to_json
  end

  def expired?
    return true unless @expires_at.is_a?(Time)

    Time.now > @expires_at
  end

  def valid?
    return false if @access_token.nil?
    return false if expired?

    true
  end

  private

  def update_data(data_hash)
    return unless data_hash.is_a?(Hash)

    @data.merge!(data_hash)
    update_expiry(@data['expires_in'])
    @access_token = @data['access_token']
    @refresh_token = @data['refresh_token']
    update_user_info
  end

  def update_user_info
    return unless (id = @data['id_token'])

    @user_info = JWT.decode(id, nil, false)&.first
  end

  def update_expiry(seconds)
    seconds = seconds.to_i
    return unless seconds.positive?

    @expires_in = seconds
    @expires_at = Time.now + seconds
  end
end

class TokenManager
  TOKEN_TABLE_CREATE = <<~SQL_CREATE
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE TABLE IF NOT EXISTS oauth_tokens (
        id SERIAL PRIMARY KEY,
        service_name VARCHAR(255) NOT NULL,
        refresh_token TEXT NOT NULL,
        last_updated TIMESTAMP WITHOUT TIME ZONE,
        expires_at TIMESTAMP WITHOUT TIME ZONE,
        iv TEXT NOT NULL,
        UNIQUE(service_name)
    );
  SQL_CREATE

  TOKEN_TABLE_INSERT = <<~SQL_INSERT
    INSERT INTO oauth_tokens (service_name, refresh_token, iv, expires_at, last_updated)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (service_name)
      DO UPDATE SET
        refresh_token = EXCLUDED.refresh_token,
        iv = EXCLUDED.iv,
        last_updated = EXCLUDED.last_updated,
        expires_at = EXCLUDED.expires_at
  SQL_INSERT

  TOKEN_TABLE_QUERY = <<~SQL_QUERY
    SELECT * FROM oauth_tokens WHERE service_name = $1
  SQL_QUERY

  TOKEN_TABLE_QUERY_ALL = <<~SQL_QUERY
    SELECT * FROM oauth_tokens
  SQL_QUERY

  PREPARED = [
    ['insert_update_token', TOKEN_TABLE_INSERT],
    ['query_token', TOKEN_TABLE_QUERY]
  ].freeze

  DELETE_ALL_ROWS = 'DELETE FROM oauth_tokens'

  def initialize
    @tokens = {}
    encryption_key = ENV.fetch('PG_CRYPTO_TOKEN', nil)
    @encryptor = Encryptor.new(encryption_key)
    setup_token_table
  end

  def delete_token(token, &block)
    DB.exec(
      "DELETE FROM oauth_tokens WHERE service_name = '#{token.service}';"
    ) do |res|
      block.call(res)
    end
  end

  def store_token(token, &block)
    encrypted = @encryptor.encrypt(token.to_json)
    DB.exec_prepared(
      'insert_update_token',
      [token.service, encrypted[:encrypted_data], encrypted[:iv], token.expires_at, Time.now]
    ) do |res|
      LOG.debug([:token_stored_calling, block, :or, res])
      next block.call(nil) unless res

      token.iv = encrypted[:iv]
      @tokens[token.service] = token
      block.call(token)
    end
  end

  def [](key)
    @tokens[key]
  end

  def keys
    @tokens.keys
  end

  def each
    @tokens.each
  end

  private

  def token_query_result(result)
    return {} if result.ntuples.zero?

    token_decrypt(result.first)
  end

  def setup_token_table
    # DB.exec(DELETE_ALL_ROWS) do |res|
    DB.exec(TOKEN_TABLE_CREATE) do |res|
      # token_setup_result(res)
      setup_prepared_statements(res)
    end
  end

  def setup_prepared_statements(result, prepared = PREPARED.dup)
    LOG.debug([:previous_statement_success, result.result_status == 1])
    return query_token_result(result) if prepared.empty?

    DB.prepare(*prepared.shift) do |res|
      setup_prepared_statements(res, prepared)
    end
  end

  def query_token_result(_result)
    DB.exec(TOKEN_TABLE_QUERY_ALL) do |res|
      # LOG.debug([res, res.result_status, res.ntuples, res.first])
      load_tokens_result(res)
    end
  end

  def load_tokens_result(result)
    LOG.debug([:load_tokens_result, result.result_status == 1])
    result.each do |row|
      tok = token_decrypt(row)
      @tokens[tok.service] = tok
    end
  end

  def token_decrypt(row)
    decrypted_token = JSON.parse(@encryptor.decrypt(row['refresh_token'], row['iv']))
    tok = AuthToken.new(
      row['service_name'],
      decrypted_token
    )
    tok.expires_at = Time.parse(row['expires_at'])
    tok.iv = row['iv']
    tok
  end
end

TOK = TokenManager.new unless defined? TOK
