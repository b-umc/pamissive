# frozen_string_literal: true

require 'json'
require 'uri'
require 'openssl'
require 'base64'
require 'time'
require 'cgi'
require 'digest/sha1'
require 'set'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative 'auth_server'
require_relative 'pg_create'
require_relative '../../nonblock_HTTP/manager'

class QuickbooksTime
  include TimeoutInterface
  include PGCreate

  API_NAME = 'quickbooks_time'
  API_ENDPOINT = 'https://rest.tsheets.com/api/v1'
  EPOCH_8601 = '20000101'
  TS_PER_PAGE = 200
  USERS_PER_PAGE = 200
  EPOCH_TS    = Time.utc(2000, 1, 1) # your EPOCH_8601, but as a Time

  MISSIVE_CHANNEL_ID = ENV.fetch('MISSIVE_QBT_CHANNEL_ID', nil)
  BACKFILL_JOB_DELAY = 5
  TYPE_COLORS = { regular: '#2266ED', manual: '#b7791f' }.freeze
  JOBCODE_CHUNK_SIZE = 50


  STATUS_COLORS = {
    'unbilled'    => '#2266ED',
    'generated'   => '#6b7280',
    'sent'        => '#5c6ac4',
    'paid'        => '#10b981',
    'overdue'     => '#ef4444',
    'do_not_bill' => '#6b7280',
    'expired'     => '#b7791f',
    'unknown'     => '#9ca3af'
  }.freeze

  def initialize(port: 8080)
    @server = NonBlockHTTP::Manager.server(port: port)
    @auth = AuthServer.new(@server, method(:authorized))
    @backfill_in_progress = false
    @user_cache = {}
    create_tables
    ensure_aux_tables
    run_migrations
  end

  def debug_probe_job!(job_id, days: 30)
    end_date = Time.now
    start_date = end_date - days * 24 * 60 * 60
    ids = all_jobcode_ids_for(job_id)
    LOG.debug [:probe_ids, job_id, :count, ids.size, :ids_sample, ids.first(20)]
    fetch_timesheets_for_jobcodes(ids, start_date, end_date) do |rows|
      sample = rows.first(3).map { |r|
        r.slice('id','jobcode_id','user_id','date','duration','start','end')
      }
      LOG.debug [:probe_rows, job_id, :total, rows.size, :sample, sample]
    end
  end

  def auth_url
    @auth.auth_url
  end

  def status
    @auth.status
  end

  def sync_timesheets_for_job(jobsite_id, since: nil, until_time: Time.now, &callback)
    DB.exec_params('SELECT last_successful_sync FROM quickbooks_time_backfill_status WHERE quickbooks_time_jobsite_id=$1', [jobsite_id]) do |res|
      last_sync = since || (res.ntuples.positive? ? Time.parse(res[0]['last_successful_sync']) : nil)
      end_date   = until_time
      start_date = last_sync || (end_date - 30 * 24 * 60 * 60)
  
      ids = all_jobcode_ids_for(jobsite_id)
      LOG.debug [:backfill_window, jobsite_id, :descendant_ids, ids.size, :range, start_date.strftime('%F'), end_date.strftime('%F')]
  
      fetch_timesheets_for_jobcodes(ids, start_date, end_date) do |timesheets|
        LOG.debug [:fetched_ts, jobsite_id, :entries, timesheets.size]
        if timesheets.empty?
          update_backfill_status(jobsite_id, end_date)
          next callback&.call(true)
        end
  
        remaining = timesheets.size
        changed_any = false
  
        timesheets.each do |ts|
          upsert_ts_and_log!(jobsite_id, ts) do |changed|
            changed_any ||= changed
            remaining -= 1
            if remaining.zero?
              update_backfill_status(jobsite_id, end_date)
              rebuild_overview!(jobsite_id) { |ok| callback&.call(ok && changed_any) }
            end
          end
        end
      end
    end
  rescue => e
    LOG.error [:sync_timesheets_for_job_failed, jobsite_id, e.message]
    callback&.call(false)
  end
  

  def handle_event(body)
    data = JSON.parse(body)
    LOG.debug([:qbt_event, data])
    event_type = data.keys.first
    handler_method = "#{event_type.chomp('s')}_updated".to_sym

    if respond_to?(handler_method)
      data[event_type].each_value do |timesheet_data|
        timesheet_updated(timesheet_data) # Real-time events are fire-and-forget
      end
    end
  end

  def api_request(endpoint, &block)
    headers = { 'Authorization' => "Bearer #{@auth.token.access_token}" }
    url = "#{API_ENDPOINT}/#{endpoint}"

    NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }, log_debug: true) do |response|
      next block.call(nil) unless response
      if response.code == 404 && endpoint.start_with?('timesheets')
        LOG.debug "Received 404 for timesheets endpoint, likely means no entries found."
        next block.call({ 'results' => { 'timesheets' => {} } })
      end
      
      raise "QuickBooks Time API Error: #{response.code} #{response.body}" unless response.code == 200

      begin
        parsed_body = JSON.parse(response.body)
        block.call(parsed_body)
      rescue JSON::ParserError => e
        LOG.error "Failed to parse JSON response from #{endpoint}. Body was: #{response.body.inspect}"
        LOG.error "ParserError: #{e.message}"
        block.call({})
      end
    end
  end

  def timesheet_updated(data, &callback)
    job_id = data['jobcode_id']
    upsert_ts_and_log!(job_id, data) do |changed|
      rebuild_overview!(job_id) { |ok| callback&.call(ok && changed) }
    end
  end

  def upsert_ts_and_log!(job_id, ts, log: true, &callback)
    tsid    = ts['id']
    user_id = ts['user_id']
    date    = ts['date']
    secs    = ts['duration'].to_i
    notes   = (ts['notes'] || '').strip
    hash    = Digest::SHA1.hexdigest([user_id, date, secs, notes].join('|'))
  
    DB.exec_params('SELECT last_hash FROM quickbooks_time_timesheets WHERE id=$1', [tsid]) do |res|
      new_record = res.ntuples.zero?
      changed = new_record || (res[0]['last_hash'] != hash)
  
      if new_record
        DB.exec_params(
          'INSERT INTO quickbooks_time_timesheets (id, quickbooks_time_jobsite_id, user_id, date, duration_seconds, notes, last_hash)
           VALUES ($1,$2,$3,$4,$5,$6,$7)',
          [tsid, job_id, user_id, date, secs, notes, hash]
        ) { }
        next log_timesheet_event!(job_id, :created, ts){ callback&.call(true) } if log
        next callback&.call(true)    
      elsif changed
        DB.exec_params(
          'UPDATE quickbooks_time_timesheets SET user_id=$1, date=$2, duration_seconds=$3, notes=$4, last_hash=$5, updated_at=now() WHERE id=$6',
          [user_id, date, secs, notes, hash, tsid]
        ) { }
        next log_timesheet_event!(job_id, :updated, ts){ callback&.call(true) } if log
        next callback&.call(true)
      else
        callback&.call(false)
      end
    end
  rescue => e
    LOG.error [:upsert_ts_failed, e.message]
    callback&.call(false)
  end
  

  def log_timesheet_event!(job_id, kind, ts, &callback)
    user_id = ts['user_id']
    get_qbt_user_details(user_id) do |user|
      tech  = "#{user['first_name']} #{user['last_name']}"
      emoji = (kind == :created ? "👷" : "✏️")
      dur   = fmt_hm(ts['duration'])
      note  = (ts['notes'] || '').strip
      md = +"#{emoji} **#{tech}** #{kind == :created ? 'logged' : 'updated'} #{dur} on #{ts['date']} (TSID `#{ts['id']}`)."
      md << "\n> _#{note}_" unless note.empty?
      append_post_markdown!(job_id, md, color: nil) { |ok| callback&.call(ok) }
    end
  end
  


  def log_admin_action!(job_id, md, color: nil, &callback)
    ensure_conversation(job_id, nil) do |conversation_id|
      next callback&.call(false) unless conversation_id
      append_post_markdown!(conversation_id, md, color: color) { |ok| callback&.call(ok) if callback }
    end
  end

  def append_post_markdown!(job_id, markdown, color:, username: 'QuickBooks Time', &callback)
    get_full_job_name(job_id) do |job_name|
      payload = {
        posts: {
          # this is the key: let Missive thread by reference
          references: [job_ref(job_id)],
          username: username,
          conversation_subject: "QuickBooks Time: #{job_name}",
          conversation_color: color,
          notification: {
            title: "QuickBooks Time • #{job_name}",
            body: notif_body_from_markdown(markdown)
          },
          attachments: [
            { markdown: markdown, timestamp: Time.now.to_i, color: color }
          ],
          # organization: MISSIVE_ORG_ID,
          # team: MISSIVE_TEAM_ID,
          add_to_inbox: false,
          add_to_team_inbox: false
        }.compact
      }
  
      MISSIVE.channel_post('posts', payload) do |res|
        ok = res && res.code.to_i.between?(200, 299)
        LOG.error [:post_append_failed, res&.code, res&.body] unless ok
        callback&.call(ok)
      end
    end
  end  

  def rebuild_overview!(job_id, &callback)
    ensure_overview_state(job_id) do |state|
      next callback&.call(false) unless state
      unbilled_totals(job_id) do |calc|
        status = state['status'] || 'unbilled'
        render_overview_markdown(job_id, calc, status: status, invoice_url: state['invoice_url']) do |md|
          # delete old overview post if we have its id
          if (old = state['overview_post_id'])
            MISSIVE.channel_delete("posts/#{old}") { |_r| }
          end
  
          get_full_job_name(job_id) do |job_name|
            payload = {
              posts: {
                references: [job_ref(job_id)],
                username: 'Overview',
                conversation_subject: "QuickBooks Time: #{job_name}",
                conversation_color: STATUS_COLORS[status],
                notification: {
                  title: "QBT Overview • #{job_name}",
                  body: notif_body_from_markdown(md, limit: 180)
                },
                attachments: [
                  { markdown: md, timestamp: Time.now.to_i, color: STATUS_COLORS[status] }
                ],
                # organization: MISSIVE_ORG_ID,
                # team: MISSIVE_TEAM_ID,
                add_to_inbox: false,
                add_to_team_inbox: false
              }.compact
            }
  
            MISSIVE.channel_post('posts', payload) do |res|
              ok = res && res.code.to_i.between?(200, 299)
              post_id = ok ? (JSON.parse(res.body)['posts']['id'] rescue nil) : nil
              if ok && post_id
                DB.exec_params(
                  'UPDATE quickbooks_time_overview_state SET overview_post_id=$1, total_unbilled_seconds=$2, updated_at=now() WHERE quickbooks_time_jobsite_id=$3',
                  [post_id, calc[:total_seconds], job_id]
                ) { }
              else
                LOG.error [:overview_upsert_failed, res&.code, res&.body]
              end
              callback&.call(ok)
            end
          end
        end
      end
    end
  rescue => e
    LOG.error [:rebuild_overview_failed, e.message]
    callback&.call(false)
  end
  
  def ensure_overview_state(job_id, &callback)
    DB.exec_params('SELECT * FROM quickbooks_time_overview_state WHERE quickbooks_time_jobsite_id=$1', [job_id]) do |res|
      if res.ntuples.positive?
        next callback.call(res[0])
      end
      DB.exec_params(
        'INSERT INTO quickbooks_time_overview_state (quickbooks_time_jobsite_id) VALUES ($1) RETURNING quickbooks_time_jobsite_id, overview_post_id, status, invoice_id, invoice_url, total_unbilled_seconds',
        [job_id]
      ) { |st| callback.call(st[0]) }
    end
  end

  def render_overview_markdown(job_id, calc, status:, invoice_url:, &callback)
    get_full_job_name(job_id) do |job_name|
      job_name ||= "Job ##{job_id}"

      lines = []
      lines << "**#{job_name}**"
      lines << "_Status_: **#{status.upcase}**#{invoice_url ? " • [Invoice](#{invoice_url})" : ''}"
      lines << ""
      lines << "**Unbilled summary**"
      lines << ""
      lines << "| Week | Tech | Hours | Entries |"
      lines << "|---|---:|---:|---:|"
      (calc[:by_week_tech] || {}).each do |wk, techs|
        techs.each do |tech, stat|
          lines << "| #{wk} | #{tech} | #{(stat[:seconds]/3600.0).round(2)} | #{stat[:count]} |"
        end
      end
      lines << ""
      lines << "**Total unbilled:** #{fmt_hm(calc[:total_seconds])}"
      lines << ""
      lines << "```qbtmeta"
      lines <<({ jobsite_id: job_id, generated_at: Time.now.utc.iso8601, status: status, total_seconds: calc[:total_seconds] }.to_json)
      lines << "```"
      callback.call(lines.join("\n"))
    end
  end

  def unbilled_totals(job_id, &callback)
    DB.exec_params('SELECT * FROM quickbooks_time_timesheets WHERE quickbooks_time_jobsite_id=$1 AND billed=false', [job_id]) do |r|
      rows = r.to_a
      user_ids = rows.map { |row| row['user_id'].to_i }.uniq
      missing = user_ids.reject { |id| @user_cache.key?(id) }
      if missing.any?
        api_request("users?ids=#{missing.join(',')}") do |resp|
          (resp.dig('results', 'users') || {}).each do |_, u|
            @user_cache[u['id']] = u
          end
          compute_unbilled_totals(rows, &callback)
        end
      else
        compute_unbilled_totals(rows, &callback)
      end
    end
  end

  def compute_unbilled_totals(rows, &callback)
    rows.each do |row|
      u = @user_cache[row['user_id'].to_i]
      row['tech'] = u ? "#{u['first_name']} #{u['last_name']}" : "User##{row['user_id']}"
    end
    by_week_tech = Hash.new { |h,k| h[k] = Hash.new { |hh,kk| hh[kk] = { seconds: 0, count: 0 } } }
    total = 0
    rows.each do |r|
      d = Date.parse(r['date'])
      wk = "#{d.cwyear}-W#{d.cweek}"
      secs = r['duration_seconds'].to_i
      by_week_tech[wk][r['tech']][:seconds] += secs
      by_week_tech[wk][r['tech']][:count]   += 1
      total += secs
    end
    callback.call({ total_seconds: total, by_week_tech: by_week_tech })
  end

  def admin_generate_invoice!(job_id, ts_ids:, invoice_id:, invoice_url:, admin_name:, &callback)
    DB.exec_params('UPDATE quickbooks_time_timesheets SET billed=true, billed_invoice_id=$1, updated_at=now() WHERE quickbooks_time_jobsite_id=$2 AND id = ANY($3::BIGINT[])',
                   [invoice_id, job_id, "{#{ts_ids.join(',')}}"]) { }
    md = "🧾 **#{admin_name}** generated invoice [`#{invoice_id}`](#{invoice_url}) for #{ts_ids.size} entries."
    log_admin_action!(job_id, md, color: STATUS_COLORS['generated']) do |_|
      DB.exec_params('UPDATE quickbooks_time_overview_state SET status=$1, invoice_id=$2, invoice_url=$3, updated_at=now() WHERE quickbooks_time_jobsite_id=$4',
                     ['generated', invoice_id, invoice_url, job_id]) { }
      rebuild_overview!(job_id, &callback)
    end
  end

  def admin_mark_paid!(job_id, admin_name:, &callback)
    md = "💸 **#{admin_name}** marked invoice as **PAID**."
    log_admin_action!(job_id, md, color: STATUS_COLORS['paid']) do |_|
      DB.exec_params('UPDATE quickbooks_time_overview_state SET status=$1, updated_at=now() WHERE quickbooks_time_jobsite_id=$2',
                     ['paid', job_id]) { }
      rebuild_overview!(job_id, &callback)
    end
  end

  def admin_link_qbo!(job_id, client_name:, admin_name:, &callback)
    md = "🔗 **#{admin_name}** linked jobsite to QBO client **#{client_name}**."
    log_admin_action!(job_id, md, color: nil) { |_ok| rebuild_overview!(job_id, &callback) }
  end

  private

  def sync_all_users!(per_page: USERS_PER_PAGE, &callback)
    page = 1
    total = 0
  
    step = proc do
      q = {
        active: 'both',
        supplemental_data: 'yes',
        per_page: per_page,
        page: page
      }
      LOG.debug [:users_sync_page, page, :per_page, per_page]
  
      api_request("users?#{URI.encode_www_form(q)}") do |resp|
        hydrate_users_from_supplemental!(resp)
  
        users = (resp.dig('results', 'users') || {}).values
        if users.any?
          users.each do |u|
            @user_cache[u['id']] = u
            upsert_user_row!(u) rescue nil
          end
          total += users.size
          LOG.debug [:users_sync_count, :this_page, users.size, :total, total]
        else
          LOG.debug [:users_sync_empty_page, page]
        end
  
        if resp['more']
          page += 1
          add_timeout(step, 0)
        else
          LOG.debug [:users_sync_done, :total, total]
          callback&.call(true)
        end
      end
    end
  
    step.call
  rescue => e
    LOG.error [:users_sync_failed, e.message]
    callback&.call(false)
  end

  def upsert_user_row!(u)
    DB.exec_params(%{
      INSERT INTO quickbooks_time_users
        (id, first_name, last_name, username, email, active, last_modified, created, raw)
      VALUES
        ($1,$2,$3,$4,$5,$6,$7,$8,$9)
      ON CONFLICT (id) DO UPDATE SET
        first_name = EXCLUDED.first_name,
        last_name  = EXCLUDED.last_name,
        username   = EXCLUDED.username,
        email      = EXCLUDED.email,
        active     = EXCLUDED.active,
        last_modified = EXCLUDED.last_modified,
        created    = EXCLUDED.created,
        raw        = EXCLUDED.raw
    }, [
      u['id'],
      u['first_name'],
      u['last_name'],
      u['username'],
      u['email'],
      (u['active'] == true || u['active'].to_s.downcase.start_with?('t')),
      (Time.parse(u['last_modified']) rescue nil),
      (Time.parse(u['created']) rescue nil),
      JSON.dump(u)
    ]) { }
  end
  
  def hydrate_users_from_supplemental!(resp)
    sup = resp['supplemental_data'] || {}
    users = sup['users'] || {}
    return if users.empty?
    users.each_value do |u|
      @user_cache[u['id']] = u
      upsert_user_row!(u) rescue nil
    end
  end
  

  def rebuild_touched_overviews!(job_ids, &callback)
    return callback&.call(true) if job_ids.nil? || job_ids.empty?
    i = 0
    step = proc do
      if i >= job_ids.size
        next callback&.call(true)
      end
      jid = job_ids[i]; i += 1
      rebuild_overview!(jid) { add_timeout(step, 0) }
    end
    step.call
  end
  
  def get_last_timesheet_sync
    DB.exec_params('SELECT last_successful_sync FROM api_sync_logs WHERE api_name=$1 LIMIT 1', ['quickbooks_time_timesheets']) do |r|
      next nil if r.ntuples.zero?
      next Time.parse(r[0]['last_successful_sync'])
    end
  end
  
  def update_timesheet_sync_success(ts)
    sql = %{
      INSERT INTO api_sync_logs (api_name, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (api_name) DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, ['quickbooks_time_timesheets', ts]) { |res| LOG.debug [:timesheet_sync_mark, ts, res.cmd_status] }
  end
  

  def sweep_timesheets_modified_since(modified_since:, page: 1, per_page: TS_PER_PAGE, &on_page)
    q = {
      modified_since: modified_since.utc.iso8601,
      supplemental_data: 'yes',
      per_page: per_page,
      page: page
    }
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      hydrate_users_from_supplemental!(resp)
      rows = (resp.dig('results', 'timesheets') || {}).values
      on_page.call(rows || [])
      sweep_timesheets_modified_since(modified_since: modified_since, page: page + 1, per_page: per_page, &on_page) if resp['more']
    end
  end
  

  def get_last_timesheet_sync
    DB.exec_params('SELECT last_successful_sync FROM api_sync_logs WHERE api_name=$1', ['quickbooks_time_timesheets']) do |r|
      next nil if r.ntuples.zero?
      next Time.parse(r[0]['last_successful_sync'])
    end
  end
  
  def update_timesheet_sync_success(ts)
    sql = %{
      INSERT INTO api_sync_logs (api_name, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (api_name) DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, ['quickbooks_time_timesheets', ts]) { |res| LOG.debug [:timesheet_sync_mark, ts, res.cmd_status] }
  end  

  def incremental_sync!(&callback)
    last = get_last_timesheet_sync
    return backfill_all!(&callback) unless last
  
    anchor = Time.now.utc
    touched = {}
    inflight = 0
  
    sweep_timesheets_modified_since(modified_since: last) do |batch|
      if batch.empty?
        if inflight.zero?
          update_timesheet_sync_success(anchor)
          next rebuild_touched_overviews!(touched.keys, &callback)
        end
        next
      end
  
      inflight += batch.size
      batch.each do |ts|
        job_id = ts['jobcode_id']
        upsert_ts_and_log!(job_id, ts) do |changed|
          touched[job_id] = true if changed
          inflight -= 1
        end
      end
    end
  end  

  def backfill_all!(&callback)
    anchor = Time.now.utc # mark before fetching so we don't miss edits during the run
    touched = {}
    inflight = 0
  
    sweep_timesheets_modified_since(modified_since: EPOCH_TS) do |batch|
      if batch.empty?
        # no rows on this page; if inflight is zero, we’re done
        if inflight.zero?
          update_timesheet_sync_success(anchor)
          next rebuild_touched_overviews!(touched.keys, &callback)
        end
        next
      end
  
      inflight += batch.size
      batch.each do |ts|
        job_id = ts['jobcode_id']
        upsert_ts_and_log!(job_id, ts, log: true) do |changed|
          touched[job_id] = true if changed
          inflight -= 1
          if inflight.zero? # page finished (or whole sweep if this was the last page)
            # NOTE: we don’t know if there are more pages yet; pager will keep calling us.
            # When pager fully completes, we’ll hit the empty-batch path above with inflight==0.
          end
        end
      end
    end
  end
  
  def backfill_window!(start_date:, end_date:, log_posts: false, &callback)
    touched = Set.new
    inflight = 0
    done = proc do
      next unless inflight.zero?
      # rebuild once per job (keeps the overview last)
      jobs = touched.to_a
      next callback&.call(true) if jobs.empty?
      idx = 0
      rebuild = proc do
        if idx >= jobs.size
          next callback&.call(true)
        end
        job_id = jobs[idx]
        idx += 1
        rebuild_overview!(job_id) { |_ok| add_timeout(rebuild, 0.25) }
      end
      rebuild.call
    end

    stream_timesheets(start_date: start_date, end_date: end_date) do |batch|
      if batch.empty?
        next done.call
      end
      inflight += batch.size
      batch.each do |ts|
        job_id = ts['jobcode_id']
        upsert_ts_and_log!(job_id, ts, log: log_posts) do |changed|
          touched << job_id if changed
          inflight -= 1
          done.call if inflight.zero?
        end
      end
    end
  end

  def stream_timesheets_modified_since(modified_since:, per_page: TS_PER_PAGE, page: 1, &on_batch)
    q = {
      modified_since: modified_since.utc.iso8601,
      per_page: per_page,
      page: page
    }
    LOG.debug [:ts_stream_mod_since, q[:modified_since], :page, page]
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      rows = (resp.dig('results', 'timesheets') || {}).values
      on_batch.call(rows || [])
      if resp['more']
        stream_timesheets_modified_since(modified_since: modified_since, per_page: per_page, page: page + 1, &on_batch)
      end
    end
  end  

  def stream_timesheets(start_date:, end_date:, per_page: TS_PER_PAGE, page: 1, &on_batch)
    q = {
      start_date: start_date.strftime('%Y-%m-%d'),
      end_date:   end_date.strftime('%Y-%m-%d'),
      per_page:   per_page,
      page:       page
    }
    LOG.debug [:ts_stream_page, q[:start_date], q[:end_date], :page, page]
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      rows = (resp.dig('results', 'timesheets') || {}).values
      on_batch.call(rows || [])
      if resp['more']
        stream_timesheets(start_date: start_date, end_date: end_date, per_page: per_page, page: page + 1, &on_batch)
      end
    end
  end

  def parse_bool(v)
    case v
    when true, 't', 'true', 1, '1' then true
    when false, 'f', 'false', 0, '0' then false
    else nil
    end
  end
  
  def all_jobcode_ids_for(job_id, only_active: true)
    ids = []
  
    sql = %{
      WITH RECURSIVE tree AS (
        SELECT id, parent_id, active
        FROM quickbooks_time_jobs
        WHERE id = $1
        UNION ALL
        SELECT j.id, j.parent_id, j.active
        FROM quickbooks_time_jobs j
        JOIN tree t ON j.parent_id = t.id
      )
      SELECT id, active FROM tree
    }
  
    DB.exec_params(sql, [job_id]) do |res|
      res.each do |row|
        active = parse_bool(row['active'])
        ids << row['id'].to_i unless only_active && active == false
      end
    end
  
    # never return empty; at least include the root so we do *some* fetch
    ids = [job_id.to_i] if ids.empty?
  
    LOG.debug [:jobcode_tree, job_id, :count, ids.size, :first10, ids.first(10)]
    ids.uniq
  rescue => e
    LOG.error [:jobcode_tree_failed, job_id, e.message]
    [job_id.to_i]
  end
  # stable per job
  def job_ref(job_id)
    "qbt:job:#{job_id}"
  end

  def notif_body_from_markdown(md, limit: 140)
    # quick & dirty: strip most markdown for the notif preview
    plain = md.gsub(/```.*?```/m, '')
              .gsub(/`([^`]*)`/, '\1')
              .gsub(/\*\*([^*]+)\*\*/, '\1')
              .gsub(/\*([^*]+)\*/, '\1')
              .gsub(/^>\s*/, '')
              .gsub(/\[(.*?)\]\((.*?)\)/, '\1')
              .gsub(/[_#]/, '')
              .strip
    plain.length > limit ? "#{plain[0, limit - 1]}…" : plain
  end

  def classify_entry(ts)
    # Prefer explicit API type when available
    t = (ts['type'] || ts['Type'] || '').to_s.downcase
    return :manual  if t == 'manual'
    return :regular if t == 'regular'

    # Fallback heuristic: manual "time card" lacks start/end
    has_start = ts['start'].to_s.strip != ''
    has_end   = ts['end'].to_s.strip   != ''
    has_start || has_end ? :regular : :manual
  rescue StandardError
    :regular
  end

  def clocked_likely?(ts, threshold_minutes: 5)
    s = Time.parse(ts['start']) rescue nil
    e = Time.parse(ts['end'])   rescue nil
    created = Time.parse(ts['created']) rescue nil
    return false unless e && created
    (created - e).abs <= threshold_minutes * 60
  end


  def ensure_conversation(job_id, seed_ts, &callback)
    sql = 'SELECT missive_conversation_id FROM quickbooks_time_jobsite_conversations WHERE quickbooks_time_jobsite_id = $1'
    DB.exec_params(sql, [job_id]) do |res|
      next callback.call(res[0]['missive_conversation_id']) if res&.ntuples&.positive?

      get_full_job_name(job_id) do |full_name|
        if seed_ts && seed_ts['user_id']
          get_qbt_user_details(seed_ts['user_id']) do |user|
            create_conversation_message(job_id, full_name,
              to_fields: [{ id: seed_ts['user_id'].to_s,
                            username: user['username'] || user['email'],
                            name: "#{user['first_name']} #{user['last_name']}" }],
              &callback
            )
          end
        else
          create_conversation_message(job_id, full_name,
            to_fields: [{ id: 'admin', username: 'admin', name: 'Admin' }],
            &callback
          )
        end
      end
    end
  rescue => e
    LOG.error [:ensure_conversation_failed, e.message]
    callback&.call(nil)
  end

  def create_conversation_message(job_id, full_name, to_fields:, &callback)
    payload = {
      messages: {
        account: MISSIVE_CHANNEL_ID,
        from_field: { id: "job-#{job_id}", username: full_name, name: full_name },
        to_fields: to_fields,
        conversation_subject: "QuickBooks Time: #{full_name}",
        body: "Thread created",
        delivered_at: Time.now.to_i,
        add_to_inbox: false,
        add_to_team_inbox: false
      }.compact
    }
    MISSIVE.channel_post('messages', payload) do |res|
      ok = res && res.code.to_i.between?(200, 299)
      unless ok
        LOG.error [:missive_conversation_create_failed, res&.code, res&.body]
        return callback&.call(nil)
      end

      body = JSON.parse(res.body) rescue {}
      conv = body.dig('messages', 'conversation') || body.dig('messages', 'conversation', 'id')
      conv = conv['id'] if conv.is_a?(Hash)
      unless conv
        LOG.error [:missive_create_parse_error, res.body]
        return callback&.call(nil)
      end

      save_conversation_mapping(job_id, conv) { callback.call(conv) }
    end
  end

  def missive_post(payload, &block)
    LOG.debug [:missive_post_payload, payload]
    MISSIVE.channel_post('posts', payload, &block)
  end

  def already_posted?(timesheet_id, &callback)
    return callback.call(false) unless timesheet_id
    DB.exec_params('SELECT 1 FROM quickbooks_time_timesheet_posts WHERE timesheet_id = $1 LIMIT 1', [timesheet_id]) do |res|
      callback.call(res && res.ntuples > 0)
    end
  end

  def save_timesheet_post(timesheet_id, jobsite_id, conversation_id, post_id)
    return unless timesheet_id && conversation_id && post_id
    sql = %{
      INSERT INTO quickbooks_time_timesheet_posts (timesheet_id, quickbooks_time_jobsite_id, missive_conversation_id, missive_post_id)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (timesheet_id) DO NOTHING
    }
    DB.exec_params(sql, [timesheet_id, jobsite_id, conversation_id, post_id]) { |r| LOG.debug [:timesheet_post_saved, r.cmd_status] }
  end

  def ts_epoch(ts)
    t = parse_time(ts['end']) || parse_time(ts['start']) || parse_time("#{ts['date']}T12:00:00Z")
    (t || Time.now).to_i
  end

  def parse_time(s)
    return nil if s.nil? || s.empty?
    Time.parse(s)
  rescue StandardError
    nil
  end

  def get_qbt_user_details(user_id, &callback)
    if @user_cache[user_id]
      LOG.debug "Using cached user details for user_id: #{user_id}"
      return callback.call(@user_cache[user_id])
    end

    LOG.debug "Fetching user details for user_id: #{user_id}"
    api_request("users?ids=#{user_id}") do |response|
      user_data = response.dig('results', 'users', user_id.to_s)
      if user_data
        @user_cache[user_id] = user_data
        callback.call(user_data)
      else
        LOG.error "Could not find user details for user_id: #{user_id}"
        callback.call({ 'first_name' => 'Unknown', 'last_name' => 'User', 'username' => "User##{user_id}" })
      end
    end
  end

  def fetch_paged_timesheets(jobsite_id, start_date, end_date, page = 1, acc = [], &callback)
    q = {
      jobcode_ids: jobsite_id,
      start_date: start_date.strftime('%Y-%m-%d'),
      end_date: end_date.strftime('%Y-%m-%d'),
      page: page
    }
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      items = resp.dig('results', 'timesheets') || {}
      acc.concat(items.values)
      if resp['more']
        fetch_paged_timesheets(jobsite_id, start_date, end_date, page + 1, acc, &callback)
      else
        callback.call(acc)
      end
    end
  end

  def fetch_timesheets_for_jobcodes(jobcode_ids, start_date, end_date, per_page: TS_PER_PAGE, &callback)
    return callback.call([]) if jobcode_ids.nil? || jobcode_ids.empty?
  
    chunks = jobcode_ids.each_slice(JOBCODE_CHUNK_SIZE).to_a
    idx = 0
    acc = []
  
    fetch_chunk = proc do
      if idx >= chunks.size
        next callback.call(acc)
      end
  
      ids = chunks[idx]
      idx += 1
  
      fetch_paged_timesheets_chunk(ids, start_date, end_date, per_page: per_page) do |rows|
        LOG.debug [:ts_chunk_done, :ids, ids.size, :rows, rows.size]
        acc.concat(rows)
        add_timeout(fetch_chunk, 0.25)
      end
    end
  
    LOG.debug [:ts_fetch_begin, :chunks, chunks.size, :range, start_date.strftime('%F'), end_date.strftime('%F')]
    fetch_chunk.call
  end
  
  def fetch_paged_timesheets_chunk(ids, start_date, end_date, page: 1, acc: [], per_page:, &callback)
    q = {
      jobcode_ids: ids.join(','),
      start_date: (start_date - 1).strftime('%Y-%m-%d'), # pad 1 day
      end_date:   (end_date   + 1).strftime('%Y-%m-%d'),
      page: page,
      per_page: per_page
    }
  
    LOG.debug [:ts_fetch_page, :page, page, :ids_count, ids.size, :range, q[:start_date], q[:end_date]]
  
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      items = resp.dig('results', 'timesheets') || {}
      acc.concat(items.values)
  
      if resp['more']
        fetch_paged_timesheets_chunk(ids, start_date, end_date, page: page + 1, acc: acc, per_page: per_page, &callback)
      else
        callback.call(acc)
      end
    end
  end

  def save_conversation_mapping(jobsite_id, conversation_id, &callback)
    sql = 'INSERT INTO quickbooks_time_jobsite_conversations (quickbooks_time_jobsite_id, missive_conversation_id) VALUES ($1, $2) ON CONFLICT (quickbooks_time_jobsite_id) DO UPDATE SET missive_conversation_id = EXCLUDED.missive_conversation_id'
    DB.exec_params(sql, [jobsite_id, conversation_id]) do |res|
      LOG.debug [:saved_conversation_mapping, jobsite_id, conversation_id, res.cmd_status]
      callback&.call
    end
  end

  def get_full_job_details(job_id, &callback)
    get_full_job_name(job_id) do |full_name|
      sql = 'SELECT * FROM quickbooks_time_jobs WHERE id = $1'
      DB.exec_params(sql, [job_id]) do |result|
        details = result && result.ntuples > 0 ? result.first : {}
        details[:full_name] = full_name
        callback.call(details)
      end
    end
  end

  def get_full_job_name(job_id, &callback)
    name_parts = []
    
    fetch_job_recursively = ->(id) {
      sql = 'SELECT name, parent_id FROM quickbooks_time_jobs WHERE id = $1'
      DB.exec_params(sql, [id]) do |result|
        if result && result.ntuples > 0
          row = result.first
          name_parts.unshift(row['name'])
          parent_id = row['parent_id'].to_i
          if parent_id > 0
            fetch_job_recursively.call(parent_id)
          else
            callback.call(name_parts.join(': '))
          end
        else
          callback.call(name_parts.unshift("Jobsite ##{id}").join(': '))
        end
      end
    }
    
    fetch_job_recursively.call(job_id)
  end

  def create_tables
    CREATE_TABLE_COMMANDS.each_value do |sql|
      DB.exec(sql) { |res| LOG.debug([:created_table, res.cmd_status]) if res }
    end
  end

  def authorized
    LOG.debug([:qbt_authorized,:begin_sync])
    # add_timeout(proc { debug_probe_job!('14897768') }, 1)
    add_timeout(
      proc do
        sync_all_users! do |ok|
          LOG.debug [:user_sync_complete, ok]
          next initial_sync_jobcodes unless ok  # still proceed, but log the failure
      
          # after users, do your normal jobcodes sync & timesheet sweep
          initial_sync_jobcodes
          # if you want, start your timesheet pager here:
          # backfill_all!  or  incremental_sync!
        end
      end,
      8
    )
    # initial_sync_jobcodes
  end

  def initial_sync_jobcodes
    get_last_sync_time(API_NAME) do |last_sync_time|
      LOG.debug([:quickbooks_time_last_sync_time, last_sync_time])
      sync_jobcodes_since(last_sync_time || EPOCH_8601)
    end
  end

  def get_last_sync_time(api_name, &callback)
    DB.exec_params('SELECT last_successful_sync FROM api_sync_logs WHERE api_name = $1', [api_name]) do |result|
      callback.call(result.ntuples.zero? ? nil : result[0]['last_successful_sync'])
    end
  end

  def sync_jobcodes_since(last_sync_time, start_position = 1)
    formatted_time = Time.parse(last_sync_time).utc.iso8601
    api_request("jobcodes?modified_since=#{formatted_time}&page=#{start_position}") do |response|
      LOG.debug([:jobcodes_response, response])
      jobcodes = response['results']['jobcodes'] || {}
      jobcodes.each_value { |job| sync_job_to_db(job) }
      if response['more']
        sync_jobcodes_since(last_sync_time, start_position + 1)
      else
        update_sync_success(API_NAME, Time.now)
      end
    end
  end

  def sync_job_to_db(job)
    LOG.debug([:quickbooks_time_insert, job])

    DB.exec_params(
      'INSERT INTO quickbooks_time_jobs (
        id, parent_id, name, short_code, type, billable, billable_rate,
        has_children, assigned_to_all, required_customfields, filtered_customfielditems,
        active, last_modified, created
      )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
       ON CONFLICT (id) DO UPDATE
       SET parent_id = EXCLUDED.parent_id,
           name = EXCLUDED.name,
           short_code = EXCLUDED.short_code,
           type = EXCLUDED.type,
           billable = EXCLUDED.billable,
           billable_rate = EXCLUDED.billable_rate,
           has_children = EXCLUDED.has_children,
           assigned_to_all = EXCLUDED.assigned_to_all,
           required_customfields = EXCLUDED.required_customfields,
           filtered_customfielditems = EXCLUDED.filtered_customfielditems,
           active = EXCLUDED.active,
           last_modified = EXCLUDED.last_modified,
           created = EXCLUDED.created',
      [
        job['id'],
        job['parent_id'],
        job['name'],
        job['short_code'],
        job['type'],
        job['billable'],
        job['billable_rate'],
        job['has_children'],
        job['assigned_to_all'],
        job['required_customfields'].to_json,
        job['filtered_customfielditems'].to_json,
        job['active'],
        job['last_modified'],
        job['created']
      ]
    ) do |result|
      LOG.debug("Synced job with ID #{job['id']} to the database #{result.cmd_status}")
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
      LOG.debug("Sync log update for #{api_name} result. #{result.cmd_status}")
      process_backfill_queue unless @backfill_in_progress
    end
  end

  def process_backfill_queue(job_ids = nil)
    if job_ids.nil?
      return if @backfill_in_progress
      @backfill_in_progress = true
      
      sql = %{
        SELECT j.id FROM quickbooks_time_jobs j
        LEFT JOIN quickbooks_time_backfill_status s ON j.id = s.quickbooks_time_jobsite_id
        WHERE s.id IS NULL
      }
      DB.exec(sql) do |job_result|
        if job_result && job_result.ntuples > 0
          ids_to_process = job_result.map { |row| row['id'] }
          LOG.debug "Starting backfill process for #{ids_to_process.count} jobs."
          process_backfill_queue(ids_to_process)
        else
          LOG.debug "No new jobs to backfill."
          @backfill_in_progress = false
        end
      end
      return
    end

    if job_ids.empty?
      LOG.debug "Backfill queue is empty. Process complete."
      @backfill_in_progress = false
      return
    end

    job_id_to_process = job_ids.first
    remaining_job_ids = job_ids[1..-1]

    LOG.debug "Backfilling job ##{job_id_to_process}. #{remaining_job_ids.count} jobs remaining in queue."
    sync_timesheets_for_job(job_id_to_process) do
      add_timeout(proc { process_backfill_queue(remaining_job_ids) }, BACKFILL_JOB_DELAY)
    end
  end

  def update_backfill_status(jobsite_id, timestamp)
    sql = %{
      INSERT INTO quickbooks_time_backfill_status (quickbooks_time_jobsite_id, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (quickbooks_time_jobsite_id)
      DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, [jobsite_id, timestamp]) do |res|
      LOG.debug "Updated backfill status for job ##{jobsite_id} to #{timestamp}"
    end
  end
  
  def ensure_aux_tables
    DB.exec(%{
      CREATE TABLE IF NOT EXISTS quickbooks_time_timesheet_posts (
        timesheet_id BIGINT PRIMARY KEY,
        quickbooks_time_jobsite_id BIGINT NOT NULL,
        missive_conversation_id TEXT NOT NULL,
        missive_post_id TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now()
      )
    }) { |res| LOG.debug [:created_table, res.cmd_status] if res }
  end
  
  def run_migrations
    DB.exec(%{
      DO $$
      BEGIN
        IF EXISTS(SELECT * FROM information_schema.columns WHERE table_name='quickbooks_time_timesheet_posts' AND column_name='workforce_jobsite_id') THEN
          ALTER TABLE quickbooks_time_timesheet_posts RENAME COLUMN workforce_jobsite_id TO quickbooks_time_jobsite_id;
          RAISE NOTICE 'Renamed column in quickbooks_time_timesheet_posts';
        END IF;
      END $$;
    })

    DB.exec(%{
      DO $$
      BEGIN
        IF EXISTS(SELECT * FROM information_schema.columns WHERE table_name='quickbooks_time_jobsite_conversations' AND column_name='workforce_jobsite_id') THEN
          ALTER TABLE quickbooks_time_jobsite_conversations RENAME COLUMN workforce_jobsite_id TO quickbooks_time_jobsite_id;
          RAISE NOTICE 'Renamed column in quickbooks_time_jobsite_conversations';
        END IF;
      END $$;
    })

    DB.exec(%{
      DO $$
      BEGIN
        IF EXISTS(SELECT * FROM information_schema.columns WHERE table_name='quickbooks_time_backfill_status' AND column_name='workforce_jobsite_id') THEN
          ALTER TABLE quickbooks_time_backfill_status RENAME COLUMN workforce_jobsite_id TO quickbooks_time_jobsite_id;
          RAISE NOTICE 'Renamed column in quickbooks_time_backfill_status';
        END IF;
      END $$;
    })
  end

  def fmt_hm(seconds)
    h = seconds.to_i / 3600
    m = (seconds.to_i % 3600) / 60
    "#{h}h #{m}m"
  end
end

QBT = QuickbooksTime.new unless defined?(QBT)
