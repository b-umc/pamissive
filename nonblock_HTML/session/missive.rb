# frozen_string_literal: true

require 'erb'
# require_relative '../../api/quickbooks_time/quickbooks_time'
require_relative '../../api/missive/missive'

class NonBlockHTML::Server; end
class NonBlockHTML::Server::Session; end

class NonBlockHTML::Server::Session::Missive
  CONV_REGISTER = %[
    const socket = event.detail.socketWrapper;

    if (!registeredForMissiveChanges) {
      Missive.on( 'change:conversations',
        (ids) => {
          Missive.fetchConversations(ids).then((conversations) => {
              const conversationData = {
                'cat': 'mis',
                'act': 'conv',
                'conversations': conversations
              };
              socket.send(JSON.stringify(conversationData));
            }
          );
        },
        { retroactive: true }
      );

      // Mark the script as executed
      registeredForMissiveChanges = true;
    }
  ]

  FETCH_USERS = %[
    const socket = event.detail.socketWrapper;

    Missive.fetchUsers().then((users) => {
      const userData = {
        'cat': 'mis',
        'act': 'user',
        'users': users
      };
      socket.send(JSON.stringify(userData));
    });
  ]

  FETCH_LABELS = %[
    const socket = event.detail.socketWrapper;

    Missive.fetchLabels().then((labels) => {
      const labelData = {
        'cat': 'mis',
        'act': 'lab',
        'labels': labels
      };
      socket.send(JSON.stringify(labelData));
    });
  ]

  attr_reader :name, :opened, :state

  def initialize(session)
    @opened = true
    @name = 'Missive'
    @tab = 'mis'
    @session = session
    @state = { jobsites: [], customers: [] }
    init_erb
    subscribe_events
    @registered_for_conversations = false

    send_js(FETCH_USERS)
  end

  def clicked
    @opened = !@opened
    send_header
    send_message(content) if @opened
  end

  def on_message(data)
    case data['act']
    when 'conv' then conversation_change(data)
    when 'user' then user_change(data)
    when 'lab' then update_labels(data)
    else
      LOG.debug([:unknown_missive_request_from_session, data])
    end
    # refresh_content
    # @ws.send_message(data)
  end

  def refresh_content
    send_message(content)
  end

  def send_message(data)
    LOG.debug([:mis_sending_message, caller[0]])
    @session.send_message(data)
  end

  def send_js(data)
    @session.send_js(data)
  end

  def dashboard
    @dashboard.result(binding)
  end

  def content
    @content.result(binding)
  end

  def connection_card
    return '' unless (user_data = @state[:me])

    @connection_card.result(binding)
  end

  def jobsites
    @state[:jobsites]
  end

  def customers
    @state[:customers]
  end

  private

  def system_change(data)
    LOG.debug([:need_to_post_change_to_missive, data])
    # MISSIVE.channel_post('message', data) { |res| LOG.debug([:missive_message_post_response, res]) }
  end

  def subscribe_events
    # %w[
    #   quickbooks_online
    #   quickbooks_time
    #   dtools
    # ].each do |sys|
    #   EventBus.subscribe(sys, '*', method(:system_change))
    # end
  end

  def init_erb
    @dashboard = ERB.new(File.read("#{__dir__}/dashboard.html.erb"))
    @content = ERB.new(File.read("#{__dir__}/content.html.erb"))
    @user_card = ERB.new(File.read("#{__dir__}/missive_user_card.html.erb"))
    @connection_card = ERB.new(File.read("#{__dir__}/missive_connection_card.html.erb"))
  end

  def send_header
    cls = "box box-collapsable#{' box-collapsable--opened' if @opened}"
    send_message(
      {
        type: :cls,
        id: 'header-box-mis',
        class: cls
      }.to_json
    )
  end

  def display_data
    display = {
      nav: nil
    }
    @state.dig(:conversation, 'labels')&.map do |e|
      next unless (n = e.fetch('name', nil))
      next unless e[:is_jobsite]

      display_navigation(n)
    end&.flatten&.join
  end

  def display_navigation(addr)
    %(
      <p>Address: #{addr}</p>
      <a href="https://www.google.com/maps/search/?api=1&query=#{addr}" class="icon-link" target="_blank">
        <svg class="icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <path fill="none" d="M0 0h24v24H0z"/>
          <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/>
        </svg>
        Show on Maps
      </a>
      <a href="https://www.google.com/maps/dir/?api=1&destination=#{addr}" class="icon-link" target="_blank">
        <svg class="icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <path fill="none" d="M0 0h24v24H0z"/>
          <path d="M12 2L3 21h3l6-8 6 8h3L12 2z"/>
        </svg>
        Navigate
      </a>
    )
  end

  def user_card(user_data = @state[:me])
    return unless user_data

    user_name = user_data['first_name']
    user_avatar = user_data['avatar_url']
    user_id = user_data['id']

    @user_card.result(binding)
  end

  def conversation_change(data)
    conv = data['conversations'][0]
    conv['labels']&.map { |label| map_label(label) } if conv
    @state[:conversation] = conv
    send_message(content)
    publish_conversation_change
  end

  def publish_conversation_change
    EventBus.publish(
      'missive', 'conversation_changed',
      { session: @session.id, labels: @state.dig(:conversation, 'labels') }
    )
  end

  def map_label(label)
    return label unless (pid = label['parent_id'])

    label[:is_jobsite] = pid == @state[:jobsites_id]
    label[:is_customer] = pid == @state[:customers_id]
    label
  end

  def user_change(data)
    @state[:users] = data['users']
    @state[:me] = data['users'].find { |e| e['me'] }
    send_message(dashboard)
    send_js(FETCH_LABELS)
  end

  def update_labels(data)
    labels = data['labels']
    @state[:labels] = labels
    organize_labels(labels)
    send_message(content)
    register_for_conversation unless @registered_for_conversations
  end

  def organize_labels(labels)
    parents = {}
    labels.each do |label|
      pid = label['parent_id']
      next update_label_category(label) unless pid

      parents[pid] ||= []
      parents[pid] << label
    end
    @state[:jobsites] = parents[@state[:jobsites_id]]
    @state[:customers] = parents[@state[:customers_id]]
  end

  def update_label_category(label)
    @state[:jobsites_id] = label['id'] if label['name'] == 'Jobsites'
    @state[:customers_id] = label['id'] if label['name'] == 'Customers'
  end

  def register_for_conversation
    send_js(CONV_REGISTER) unless @registered_for_conversations

    @registered_for_conversations = true
  end
end
