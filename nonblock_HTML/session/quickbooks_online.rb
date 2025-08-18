# frozen_string_literal: true

require 'erb'
require_relative '../../api/quickbooks_online/quickbooks'

class NonBlockHTML::Server; end
class NonBlockHTML::Server::Session; end

class NonBlockHTML::Server::Session::Quickbooks
  QBO_STATUS_DIV = ERB.new('(
    <div id="quickbooks_status">
      <%=%>
    </div>
  ')
  QBO_CONNECTED = '<button class="button-link" disabled>QBO Connected</button>'

  QBO_DISCONNECTED = %(<button class="button" ws-send hx-vals='{"cat":"qbo", "cmd":"login"}'>QBO Connect</button>)

  QBO_CUSTOMER_CARD = %()

  attr_reader :name, :opened

  def initialize(session)
    @name = 'Quickbooks Online'
    @opened = true
    @tab = 'qbo'
    @session = session
    @state = { authorized: QBO.status }
    @dashboard = ERB.new(File.read("#{__dir__}/dashboard.html.erb"))
    @content = ERB.new(File.read("#{__dir__}/content.html.erb"))
    @connection_card = ERB.new(File.read("#{__dir__}/qbo_connection_card.html.erb"))
    init_erb
  end

  def clicked
    return begin_oauth unless @state[:authorized]

    @opened = !@opened
    send_header
    send_message(content) if @opened
  end

  def on_message(data)
    case data['act']
    when 'login' then begin_oauth
    else
      LOG.debug([:unknown_qbo_request_from_session, data])
    end
  end

  def dashboard
    @dashboard.result(binding)
  end

  def content
    @content.result(binding)
  end

  def connection_card
    return QBO_DISCONNECTED unless @state[:authorized]

    QBO_CONNECTED
  end

  def on_close(*)
    EventBus.unsubscribe('quickbooks_auth', 'authorization', method(:qbo_state))
    # EventBus.unsubscribe('missive', 'conversation_changed', method(:conversation_changed))
  end

  private

  def init_erb
    EventBus.subscribe('quickbooks_auth', 'authorization', method(:qbo_state))
    # EventBus.subscribe('missive', 'conversation_changed', method(:conversation_changed))
    qbo_state({ authorized: QBO.status })
  end

  def conversation_changed(labels)
    return unless @state[:authorized] && labels && (site = labels.find { |lab| lab[:is_jobsite] })

    LOG.debug([:qbo_searching, site['name'], caller[0]])

    QBO.search_customers(site['name']) do |res|
      LOG.debug([:qb_conversation_search_results, site['name'], res])
    end
    # query = %(SELECT * FROM Customer WHERE DisplayName LIKE '#{site['name']}')
    # query = URI.encode_www_form_component(query.strip)
    # QBO.api_request("query?query=#{query}") do |*res|
    #  LOG.debug([:qbo, res])
    # end
  end

  def send_header
    cls = "box box-collapsable#{' box-collapsable--opened' if @opened}"
    send_message(
      {
        type: :cls,
        id: 'header-box-qbo',
        class: cls
      }.to_json
    )
  end

  def display_data
    LOG.debug(:send_QBO_display)
    tools
  end

  def send_message(data)
    @session.send_message(data)
  end

  def send_js(data)
    @session.send_js(data)
  end

  def tools
    # @commands.each do |command|
    #   # something something div with a button?
    # end
  end

  def connected
    %(
      #{tools}
      #{QBO_CONNECTED}
    )
  end

  def begin_oauth
    auth_url = QBO.auth_url
    @session.send_js(%[
      if (!Missive.ENV) {
        window.open('#{auth_url}', '_blank');
      } else {
        Missive.openURL('#{auth_url}');
      }
    ])
  end

  def qbo_state(*args)
    state = args.flatten.first[:authorized] == true
    @state[:authorized] = state
    send_message(dashboard)
    # @session.refresh_content('qbo') unless @state[:authorized] == state
  end
end
