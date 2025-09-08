# frozen_string_literal: true
require 'erb'
require 'set'
require 'json'
require 'date'
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
    @invoice_modal = ERB.new(File.read("#{__dir__}/_invoice_modal.html.erb"))
    @invoice_state = { open: false, selected_ids: Set.new, tech_rates: {}, sort: 'date', group: 'tech', from_date: nil, to_date: nil, json_output: nil,
                       conversation_id: nil, jobsite_name: nil }
    EventBus.subscribe('quickbooks_time_auth', 'authorization', method(:quickbooks_time_state))
    quickbooks_time_state({ authorized: QBT.status})
    LOG.debug([:quickbooks_time_session_initialized])
  end

  def on_close(*)
    EventBus.unsubscribe('quickbooks_time_auth', 'authorization', method(:quickbooks_time_state))
  end

  def clicked
    if !@state[:authorized]
      # Allow dropdown even when unauthorized so users can see the Connect button.
      @opened = !@opened
      send_header
      send_message(content) if @opened
      return
    end

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
    when 'open_invoice' then open_invoice_modal(data['conversation_id'])
    when 'openform_step1' then openform_step2(data)
    when 'openform_finalize' then openform_finalize(data)
    when 'close_invoice' then close_invoice_modal
    when 'set_date' then set_invoice_date(data)
    when 'set_sort' then set_invoice_sort(data['val'])
    when 'set_group' then set_invoice_group(data['val'])
    when 'toggle_ts' then toggle_ts_selection(data)
    when 'set_rate' then set_rate_for_user(data)
    when 'export_json' then export_invoice_json
    else
      LOG.debug([:unknown_quickbooks_time_request_from_session, data])
    end
  end

  # Navigates to the paired Missive conversation for a given task or
  # conversation. Triggered via a Missive action and relayed through the main
  # session controller.
  # @param data [Hash] Includes either 'task_id' or 'conversation_id'.
  def paired_navigation(data)
    repo = QBT.repos.timesheets
    target_conv = repo.paired_conversation(task_id: data['task_id'],
                                           conversation_id: data['conversation_id'])
    return unless target_conv

    send_js(%[Missive.navigate({ conversationId: '#{target_conv}' });])
  end

  def connection_card
    return QBT_DISCONNECTED unless @state[:authorized]

    QBT_CONNECTED + invoice_entrypoint
  end

  def dashboard
    @dashboard.result(binding)
  end

  def content
    %(
      <div id="quickbooks_time_content" hx-swap-oob="innerHTML">
        #{display_data}
      </div>
    )
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

  # --- Invoice Builder -----------------------------------------------------

  def invoice_entrypoint
    %(
      <div class="padding-small">
        <button class="button" ws-send hx-vals='{"cat":"quickbooks_time","act":"open_invoice"}'>Generate Invoice…</button>
        <span class="text-xsmall" style="opacity:0.8; margin-left:6px;">Build from current jobsite conversation</span>
      </div>
      <div id="invoice_modal_container"></div>
    )
  end

  # --- Missive.openForm (Full screen) -------------------------------------

  def openform_step2(data)
    conv_id = data['conversation_id']
    p = data['params'] || {}
    from = (p['from'] || (Date.today - 14).to_s).to_s
    to   = (p['to']   || Date.today.to_s).to_s
    sort = (p['sort'] || 'date').to_s
    group= (p['group']|| 'tech').to_s
    preselect = p['preselect'].to_s == 'true' || p['preselect'] == true

    # Update state context for payload consistency
    @invoice_state[:from_date] = from
    @invoice_state[:to_date]   = to
    @invoice_state[:conversation_id] = conv_id
    begin
      conv = @session.instance_variable_get(:@system)['mis'].state[:conversation] rescue nil
      if conv && conv['id'].to_s == conv_id.to_s
        @invoice_state[:jobsite_name] = (conv['labels'] || []).find { |l| (l[:is_jobsite] rescue false) }&.fetch('name', nil)
      end
    rescue StandardError
      # ignore
    end

    rows = QBT.repos.timesheets.timesheets_for_job_conversation(conv_id, start_date: from, end_date: to)
    # Build options for multi-select (label = date • user • hours)
    options = rows.map do |r|
      dur = (r['duration_seconds'] || r['duration'] || 0).to_i
      hours = (dur / 3600.0)
      label = "#{r['date']} • #{r['user_name'] || ("User "+(r['user_id']||'').to_s)} • #{format('%.2f', hours)}h"
      { label: label, value: r['id'], selected: preselect }
    end
    # Tech list for rate fields
    techs = rows.map { |r| [(r['user_id'] || '').to_s, (r['user_name'] || ("User "+(r['user_id']||'').to_s))] }.uniq
    rate_fields = techs.map do |uid, uname|
      { id: "rate:#{uid}", label: "Rate — #{uname}", type: 'number', value: 0 }
    end

    js = <<~JS
      (function(){
        const ws = window.__ws;
        Missive.openForm({
          title: 'Invoice Builder — Select & Rates',
          submitLabel: 'Generate JSON',
          cancelLabel: 'Back',
          message: 'Pick entries to include and set per-tech rates. Estimated total updates after submission.',
          fields: [
            { id: 'selected', label: 'Entries', type: 'select', multiple: true, options: #{options.to_json} },
            { id: 'group', label: 'Group', type: 'select', options: [
              { label: 'By Technician', value: 'tech' },
              { label: 'By Day', value: 'day' },
              { label: 'By Week', value: 'week' }
            ], value: #{group.to_json} },
            { id: 'sort', label: 'Sort', type: 'select', options: [
              { label: 'Date', value: 'date' },
              { label: 'Technician', value: 'tech' },
              { label: 'Duration', value: 'duration' }
            ], value: #{sort.to_json} }
          ].concat(#{rate_fields.to_json}),
          onSubmit: (vals) => {
            try {
              (ws || (event && event.detail && event.detail.socketWrapper)).send(JSON.stringify({
                cat: 'quickbooks_time',
                act: 'openform_finalize',
                conversation_id: #{conv_id.to_json},
                vals: vals,
                from: #{from.to_json},
                to: #{to.to_json}
              }));
            } catch (e) { console.error('openform_finalize send error', e); }
          }
        });
      })();
    JS
    send_js(js)
  end

  def openform_finalize(data)
    conv_id = data['conversation_id']
    vals = data['vals'] || {}
    from = data['from']
    to   = data['to']
    selected = vals['selected'] || []
    selected = [selected] if selected.is_a?(String)

    rows = QBT.repos.timesheets.timesheets_for_job_conversation(conv_id, start_date: from, end_date: to)
    rows = rows.select { |r| selected.include?(r['id']) }

    # Extract rates
    tech_rates = {}
    vals.each do |k, v|
      next unless k.to_s.start_with?('rate:')
      uid = k.split(':',2)[1]
      tech_rates[uid] = v.to_f rescue 0.0
    end

    payload = build_invoice_payload_for_rows(rows, tech_rates)
    json_str = JSON.pretty_generate(payload)

    js = <<~JS
      Missive.openForm({
        title: 'Invoice JSON',
        submitLabel: 'Close',
        fields: [
          { id: 'json', label: 'Payload', type: 'textarea', value: #{json_str.to_json} }
        ]
      });
    JS
    send_js(js)
  end

  def open_invoice_modal(conversation_id = nil)
    unless @opened
      @opened = true
      send_js(%(
        (function(){
          var drawer = document.getElementById('quickbooks_time');
          if (drawer) drawer.classList.add('box-collapsable--opened');
          var arrow = document.getElementById('quickbooks_time_arrow');
          if (arrow) arrow.style.transform = 'rotate(90deg)';
        })();
      ))
      send_message(content)
    end

    if conversation_id.nil? || conversation_id.to_s.empty?
      conv = @session.instance_variable_get(:@system)['mis'].state[:conversation] rescue nil
      return unless conv
      conversation_id = conv['id']
    end
    # Use first jobsite label name if present for context
    jobsite_name = nil
    begin
      conv = @session.instance_variable_get(:@system)['mis'].state[:conversation] rescue nil
      if conv && conv['id'].to_s == conversation_id.to_s
        jobsite_name = (conv['labels'] || []).find { |l| (l[:is_jobsite] rescue false) }&.fetch('name', nil)
      end
    rescue StandardError
      jobsite_name = nil
    end

    # Default date window: last 14 days
    from = (@invoice_state[:from_date] ||= (Date.today - 14).to_s)
    to   = (@invoice_state[:to_date]   ||= Date.today.to_s)

    rows = QBT.repos.timesheets.timesheets_for_job_conversation(conversation_id, start_date: from, end_date: to)
    selected_ids = if @invoice_state[:conversation_id] != conversation_id
                     # reset selection on conversation switch
                     Set.new(rows.map { |r| r['id'] })
                   else
                     # keep prior selection but drop ids no longer present
                     @invoice_state[:selected_ids] &= rows.map { |r| r['id'] }.to_set
                   end

    @invoice_state[:open] = true
    @invoice_state[:conversation_id] = conversation_id
    @invoice_state[:jobsite_name] = jobsite_name
    @invoice_state[:selected_ids] = selected_ids
    @invoice_state[:json_output] = nil

    rows = sort_rows(rows)
    summary = compute_summary(rows, selected_ids)

    send_invoice_modal(rows, summary)
  end

  def close_invoice_modal
    @invoice_state[:open] = false
    @invoice_state[:json_output] = nil
    send_message(%(<div id="invoice_modal_container"></div>))
    # also remove backdrop/modal if lingering
    send_js("(function(){var e=document.getElementById('invoice_modal'); if(e) e.remove(); var b=document.getElementById('invoice_modal_backdrop'); if(b) b.remove();})()")
  end

  def set_invoice_date(data)
    which = data['which']
    val = (data['val'] || '').to_s
    return unless %w[from to].include?(which) && val.size == 10
    @invoice_state["#{which}_date".to_sym] = val
    open_invoice_modal
  end

  def set_invoice_sort(val)
    @invoice_state[:sort] = (val || 'date').to_s
    open_invoice_modal
  end

  def set_invoice_group(val)
    @invoice_state[:group] = (val || 'tech').to_s
    open_invoice_modal
  end

  def toggle_ts_selection(data)
    id = data['id']
    checked = (data['checked'].to_s == 'true')
    return unless id
    if checked
      @invoice_state[:selected_ids] << id
    else
      @invoice_state[:selected_ids].delete(id)
    end
    open_invoice_modal
  end

  def set_rate_for_user(data)
    uid = data['user_id']
    val = data['val']
    return unless uid
    @invoice_state[:tech_rates][uid] = val.to_f rescue 0.0
    open_invoice_modal
  end

  def export_invoice_json
    conv_id = @invoice_state[:conversation_id]
    from = @invoice_state[:from_date]
    to = @invoice_state[:to_date]
    rows = QBT.repos.timesheets.timesheets_for_job_conversation(conv_id, start_date: from, end_date: to)
    rows = sort_rows(rows)
    selected = @invoice_state[:selected_ids]
    payload = build_invoice_payload(rows, selected)
    @invoice_state[:json_output] = JSON.pretty_generate(payload)
    open_invoice_modal
  end

  def sort_rows(rows)
    case @invoice_state[:sort]
    when 'tech'
      rows.sort_by { |r| [(r['user_name'] || '').downcase, r['date'].to_s, r['id'].to_s] }
    when 'duration'
      rows.sort_by { |r| - (r['duration_seconds'] || r['duration'] || 0).to_i }
    else
      rows.sort_by { |r| [r['date'].to_s, (r['start_time'] || r['created_qbt'] || ''), r['id'].to_s] }
    end
  end

  def compute_summary(rows, selected_ids)
    by_tech = {}
    total_hours = 0.0
    rows.each do |r|
      next unless selected_ids.include?(r['id'])
      uid = (r['user_id'] || r['user'] || '').to_s
      name = r['user_name'] || ("User "+uid)
      dur = (r['duration_seconds'] || r['duration'] || 0).to_i
      hrs = dur / 3600.0
      total_hours += hrs
      t = by_tech[uid] ||= { name: name, hours: 0.0 }
      t[:hours] += hrs
    end
    estimated_total = by_tech.reduce(0.0) do |acc, (uid, info)|
      rate = @invoice_state[:tech_rates][uid] || 0.0
      acc + (info[:hours] * rate)
    end
    { by_tech: by_tech, total_hours: total_hours, estimated_total: estimated_total }
  end

  def build_invoice_payload(rows, selected_ids)
    jobsite_name = @invoice_state[:jobsite_name]
    conv_id = @invoice_state[:conversation_id]
    from = @invoice_state[:from_date]
    to   = @invoice_state[:to_date]
    groups = {}
    total_hours = 0.0

    rows.each do |r|
      next unless selected_ids.include?(r['id'])
      uid = (r['user_id'] || r['user'] || '').to_s
      uname = r['user_name'] || ("User "+uid)
      rate = @invoice_state[:tech_rates][uid] || 0.0
      dur  = (r['duration_seconds'] || r['duration'] || 0).to_i
      hrs  = dur / 3600.0
      total_hours += hrs
      groups[uid] ||= { user_id: uid, user_name: uname, rate: rate, hours: 0.0, amount: 0.0, entries: [] }
      groups[uid][:entries] << {
        id: r['id'], date: r['date'], start: r['start_time'] || r['start'], end: r['end_time'] || r['end'], duration_seconds: dur, notes: r['notes']
      }
      groups[uid][:hours] += hrs
    end

    groups.each_value do |g|
      g[:amount] = (g[:hours] * (g[:rate] || 0.0)).round(2)
    end

    total_amount = groups.values.reduce(0.0) { |acc, g| acc + g[:amount] }.round(2)
    {
      type: 'invoice_draft',
      conversation_id: conv_id,
      jobsite_name: jobsite_name,
      date_range: { from: from, to: to },
      total_hours: total_hours.round(2),
      total_amount: total_amount,
      items: groups.values
    }
  end

  def build_invoice_payload_for_rows(rows, tech_rates)
    conv_id = @invoice_state[:conversation_id]
    jobsite_name = @invoice_state[:jobsite_name]
    from = @invoice_state[:from_date]
    to   = @invoice_state[:to_date]
    groups = {}
    total_hours = 0.0

    rows.each do |r|
      uid = (r['user_id'] || r['user'] || '').to_s
      uname = r['user_name'] || ("User "+uid)
      rate = tech_rates[uid] || 0.0
      dur  = (r['duration_seconds'] || r['duration'] || 0).to_i
      hrs  = dur / 3600.0
      total_hours += hrs
      groups[uid] ||= { user_id: uid, user_name: uname, rate: rate, hours: 0.0, amount: 0.0, entries: [] }
      groups[uid][:entries] << {
        id: r['id'], date: r['date'], start: r['start_time'] || r['start'], end: r['end_time'] || r['end'], duration_seconds: dur, notes: r['notes']
      }
      groups[uid][:hours] += hrs
    end

    groups.each_value do |g|
      g[:amount] = (g[:hours] * (g[:rate] || 0.0)).round(2)
    end

    total_amount = groups.values.reduce(0.0) { |acc, g| acc + g[:amount] }.round(2)
    {
      type: 'invoice_draft',
      conversation_id: conv_id,
      jobsite_name: jobsite_name,
      date_range: { from: from, to: to },
      total_hours: total_hours.round(2),
      total_amount: total_amount,
      items: groups.values
    }
  end

  def send_invoice_modal(rows, summary)
    html = @invoice_modal.result_with_hash(invoice_state: @invoice_state, rows: rows, tech_rates: @invoice_state[:tech_rates], summary: summary)
    send_message(%(<div id="invoice_modal_container" hx-swap-oob="innerHTML">#{html}</div>))
  end

  # Missive actions are registered centrally in AuthSession#setup_missive_actions
end
