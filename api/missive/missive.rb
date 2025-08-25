# frozen_string_literal: true

require 'json'
require 'digest'
require 'pg'
require 'envkey'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
LOG.debug('Starting Missive API channel integration')
require_relative '../../nonblock_HTTP/manager'

class Missive
  module Channel; end

  include TimeoutInterface

  attr_reader :database

  ACCOUNT_ID = ENV.fetch('MISSIVE_JOBSITES_ACCOUNT_ID', nil)
  API_BEARER = ENV.fetch('MISSIVE_JOBSITES_TOKEN', nil)
  API_URL = 'https://public.missiveapp.com/v1'
  MESSAGES_ENDPOINT = "#{API_URL}/messages"
  RESYNC_INTERVAL_SECONDS = 60 * 60 * 24 # occasional polling to ensure change events weren't missed.

  HEADERS = {
    'Authorization' => "Bearer #{API_BEARER}",
    'Content-Type' => 'application/json'
  }.freeze

  def initialize
    # @http_server = NonBlockHTTP::Manager.server(port: 8080)
    # @http_server.on(
    #   CALLBACK_EVENT_PATH, method(:handle_missive_event)
    # )
  end

  def account_id
    ACCOUNT_ID
  end

  def channel_post(endpoint, body_hash, &block)
    endpoint = "#{API_URL}/#{endpoint}" unless endpoint.start_with?('http')

    LOG.debug([:sending_post_to_missive_channel, endpoint, :with, body_hash])
    NonBlockHTTP::Client::ClientSession.new.post(endpoint, { headers: HEADERS, body: body_hash.to_json }) do |response|
      # Handle any none 2xx status code as a error.
      LOG.error([:missive_post_error, response]) unless (200..299).include?(response.code)

      block.call(response) if block_given?
    end
  end

  def channel_patch(endpoint, body_hash, &block)
    endpoint = "#{API_URL}/#{endpoint}" unless endpoint.start_with?('http')

    LOG.debug([:sending_patch_to_missive_channel, endpoint, :with, body_hash])
    NonBlockHTTP::Client::ClientSession.new.patch(endpoint, { headers: HEADERS, body: body_hash.to_json }) do |response|
      # Handle any none 2xx status code as a error.
      LOG.error([:missive_patch_error, response]) unless (200..299).include?(response.code)

      block.call(response) if block_given?
    end
  end

  def channel_get(endpoint, &block)
    endpoint = "#{API_URL}/#{endpoint}" unless endpoint.start_with?('http')

    # LOG.debug([:sending_post_to_missive_channel, endpoint, :with, body_hash])
    NonBlockHTTP::Client::ClientSession.new.get(endpoint, { headers: HEADERS }) do |response|
      # Handle any none 2xx status code as a error.
      LOG.error([:missive_post_error, response]) unless (200..299).include?(response.code)

      block.call(response) if block_given?
    end
  end

  def notify(title, body)
    { title: title.to_s[0,120], body: body.to_s.gsub(/\s+/, ' ')[0,240] }
  end
  
  def channel_delete(endpoint, &block)
    endpoint = "#{API_URL}/#{endpoint}" unless endpoint.start_with?('http')
    NonBlockHTTP::Client::ClientSession.new.delete(endpoint, { headers: HEADERS }) do |response|
      LOG.error([:missive_delete_error, response]) unless (200..299).include?(response.code)
      block.call(response) if block_given?
    end
  end
  
  def post_message(account: ACCOUNT_ID, conversation: nil, from_field:, to_fields:, subject: nil, body:, delivered_at: nil, add_to_inbox: false, add_to_team_inbox: false, organization: nil, team: nil, &block)
    unless to_fields && !to_fields.empty?
      LOG.error [:missive_message_missing_to_fields]
      return block&.call(nil)
    end
    payload = {
      messages: {
        account: account,
        conversation: conversation,
        from_field: from_field,
        to_fields: to_fields,
        conversation_subject: subject,
        body: body,
        delivered_at: delivered_at,
        add_to_inbox: add_to_inbox,
        add_to_team_inbox: add_to_team_inbox,
        organization: organization,
        team: team
      }.compact
    }
    channel_post('messages', payload, &block)
  end
  
  def post_markdown(conversation:, markdown:, username: 'QuickBooks Time', color: nil, notification: nil, timestamp: Time.now.to_i, &block)
    fallback = markdown.to_s.gsub(/[*_`>#]/, '').gsub(/\s+/, ' ').strip
    payload = {
      posts: {
        conversation: conversation,
        username: username,
        notification: notification || notify('Update', fallback),
        attachments: [
          { markdown: markdown, timestamp: timestamp, color: color }.compact
        ]
      }
    }
    channel_post('posts', payload, &block)
  end
  
  def delete_post(post_id, &block)
    channel_delete("posts/#{post_id}", &block)
  end
  
  def parse_ids(response)
    body = JSON.parse(response.body) rescue {}
    {
      post_id: body.dig('posts', 'id'),
      conversation_id: body.dig('posts', 'conversation') || body.dig('messages', 'conversation'),
      message_id: body.dig('messages', 'id')
    }
  end  

  private

  def url_parameters(keywords, **kwargs)
    param_array = []
    keywords.each do |keyword|
      param_array << "#{keyword}=#{kwargs[keyword]}" if kwargs[keyword]
    end

    param_array.empty? ? '' : "?#{param_array.join('&')}"
  end

  # def handle_missive_event(request_data, response)
  #   headers = request_data.headers
  #   request_data = request_data.body
  #   return response.status = 401 if invalid_token?(headers['api-token'])

  #   data = handle_request_data(request_data)
  #   return response.status = 400 unless data

  #   LOG.debug([:handle_missive_event, data])

  #   return response.status = 404 if unsupported_event?(data['Event'])

  #   send(data['Event'], data, response)
  # end

  def unsupported_event?(event)
    return false if respond_to?(event)

    LOG.error("Unsupported Event Encountered #{event}")
    true
  end

  def handle_request_data(data)
    JSON.parse(data)
  rescue JSON::ParserError => e
    LOG.error([:error_parsing_json_data, e, e.backtrace, data])
    nil
  end
end

MISSIVE = Missive.new unless defined? MISSIVE
