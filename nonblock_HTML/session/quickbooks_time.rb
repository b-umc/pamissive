# frozen_string_literal: true
require 'erb'
require_relative '../../api/quickbooks_time/loader'

class NonBlockHTML::Server; end
class NonBlockHTML::Server::Session; end

class NonBlockHTML::Server::Session::QuickbooksTime
  QBT_CONNECTED = %(<button class="button-link" disabled>QuickbooksTime Connected</button>)

  QBT_DISCONNECTED = %(<button class="button" ws-send hx-vals='{"cat":"quickbooks_time", "act":"login"}'>QuickbooksTime Connect</button>)

  attr_reader :name, :opened

  def initialize(session)
    @name = 'QuickbooksTime'
    @tab = 'quickbooks_time'
    @opened = true
    @session = session
    @state = { authorized: QBT.status }
    @dashboard = ERB.new(File.read("#{__dir__}/dashboard.html.erb"))
    @content = ERB.new(File.read("#{__dir__}/content.html.erb"))
    EventBus.subscribe('quickbooks_time_auth', 'authorization', method(:quickbooks_time_state))
    quickbooks_time_state({ authorized: QBT.status})
    LOG.debug([:quickbooks_time_session_initialized])
  end

  def on_close(*)
    EventBus.unsubscribe('quickbooks_time_auth', 'authorization', method(:quickbooks_time_state))
  end

  def clicked
    return begin_oauth unless @state[:authorized]

    @opened = !@opened
    send_header
    send_message(content) if @opened
  end

  def refresh_content
    send_message(content)
  end

  def on_message(data)
    case data['act']
    when 'login' then begin_oauth
    else
      LOG.debug([:unknown_quickbooks_time_request_from_session, data])
    end
  end

  # Navigates to the paired Missive conversation for a given task or
  # conversation. This is triggered via a Missive action and relayed through
  # the main session controller.
  #
  # @param data [Hash] Data including either 'task_id' or 'conversation_id'.
  def paired_navigation(data)
    repo = QBT.repos.timesheets
    target_conv = repo.paired_conversation(task_id: data['task_id'],
                                           conversation_id: data['conversation_id'])
    return unless target_conv

    send_js(%[Missive.navigate({ conversationId: '#{target_conv}' });])
  end

  def connection_card
    return QBT_DISCONNECTED unless @state[:authorized]

    QBT_CONNECTED
  end

  def dashboard
    @dashboard.result(binding)
  end

  def content
    @content.result(binding)
  end

  private

  def send_header
    cls = "box box-collapsable#{' box-collapsable--opened' if @opened}"
    send_message(
      {
        type: :cls,
        id: 'header-box-quickbooks_time',
        class: cls
      }.to_json
    )
  end

  def display_data
    # This now displays the authentication status in the content area.
    connection_card
  end

  def send_message(data)
    @session.send_message(data)
  end

  def send_js(data)
    @session.send_js(data)
  end

  def begin_oauth
    auth_url = QBT.auth_url
    @session.send_js(%[
      if (!Missive.ENV) {
        window.open('#{auth_url}', '_blank');
      } else {
        Missive.openURL('#{auth_url}');
      }
    ])
  end

  def quickbooks_time_state(*args)
    state = args.flatten.first[:authorized] == true
    @state[:authorized] = state
    send_message(dashboard)
    # This will now refresh the content to reflect the new auth state.
    refresh_content if @opened
  end
end
