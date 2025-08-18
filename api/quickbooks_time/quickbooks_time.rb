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

  API_NAME         = 'quickbooks_time'
  API_ENDPOINT     = 'https://rest.tsheets.com/api/v1'
  USERS_PER_PAGE   = 20
  JOBS_PER_PAGE    = 20
  TS_PER_PAGE      = 20
  API_RATE_LIMIT   = 3

  QBT_PAGE_LIMIT   = (ENV['QBT_PAGE_LIMIT']   || '20').to_i
  QBT_RATE_INTERVAL = (ENV['QBT_RATE_INTERVAL'] || '8').to_f
  MISSIVE_POST_MIN_INTERVAL = API_RATE_LIMIT
  EPOCH_TS         = Time.utc(2000, 1, 1)

  MISSIVE_CHANNEL_ID = ENV.fetch('MISSIVE_QBT_CHANNEL_ID', nil)

  TYPE_COLORS = { regular: '#2266ED', manual: '#b7791f' }.freeze
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
    @last_qbt_request_at = Time.at(0)
    @qbt_inflight = false
    @qbt_queue = []
    @server = NonBlockHTTP::Manager.server(port: port)
    AuthServer.new(@server, method(:authorized))
    @user_cache = {}
    ensure_schema!

    init_post_sequencer!
  end

  def qbt_get(endpoint, &block)
    job = proc do
      wait = [0, (@last_qbt_request_at + QBT_RATE_INTERVAL) - Time.now].max
      add_timeout(proc {
        @last_qbt_request_at = Time.now
        api_request(endpoint) do |resp|
          @qbt_inflight = false
          block.call(resp)
          run_next_qbt_job!
        end
      }, wait)
    end
    @qbt_queue << job
    run_next_qbt_job!
  end
  
  def run_next_qbt_job!
    return if @qbt_inflight
    job = @qbt_queue.shift
    return unless job
    @qbt_inflight = true
    job.call
  end

  def stream_timesheets(start_date:, end_date:, per_page: QBT_PAGE_LIMIT, page: 1, &on_batch)
    q = {
      start_date: start_date.strftime('%Y-%m-%d'),
      end_date:   end_date.strftime('%Y-%m-%d'),
      supplemental_data: 'yes',
      limit: per_page,
      page:  page
    }
    LOG.debug [:ts_sweep, q[:start_date], q[:end_date], :page, page, :limit, per_page]
    qbt_get("timesheets?#{URI.encode_www_form(q)}") do |resp|
      rows = (resp&.dig('results', 'timesheets') || {}).values
      on_batch.call(rows || [])
      p resp['more']
      p 'yep'
      stream_timesheets(start_date: start_date, end_date: end_date, per_page: per_page, page: page + 1, &on_batch) if resp && resp['more']
    end
  end
  
  def stream_timesheets_modified_since(modified_since:, per_page: QBT_PAGE_LIMIT, page: 1, &on_batch)
    q = {
      modified_since: modified_since.utc.iso8601,
      supplemental_data: 'yes',
      limit: per_page,
      page:  page
    }
    LOG.debug [:ts_stream_mod_since, q[:modified_since], :page, page, :limit, per_page]
    qbt_get("timesheets?#{URI.encode_www_form(q)}") do |resp|
      rows = (resp&.dig('results', 'timesheets') || {}).values
      on_batch.call(rows || [])
      p resp['more']
      p 'yep'
      stream_timesheets_modified_since(modified_since: modified_since, per_page: per_page, page: page + 1, &on_batch) if resp && resp['more']
    end
  end
  

  # --- Simple serial Missive post queue (no magic) ---

  def init_post_sequencer!
    @post_q = []
    @post_busy = false
  end

  def enqueue_post!(payload, &callback)
    @post_q << [payload, callback]
    pump_post_queue!
  end

  def pump_post_queue!
    return if @post_busy
    return if @post_q.empty?

    @post_busy = true
    payload, cb = @post_q.shift

    MISSIVE.channel_post('posts', payload) do |res|
      ok = res && res.code.to_i.between?(200, 299)
      cb&.call(ok, res)

      add_timeout(
        proc do
          @post_busy = false
          pump_post_queue!
        end,
        MISSIVE_POST_MIN_INTERVAL
      )
    end
  end

  def ensure_schema!
    DB.exec(%{
      ALTER TABLE IF EXISTS quickbooks_time_timesheets
        ADD COLUMN IF NOT EXISTS start_time TIMESTAMPTZ,
        ADD COLUMN IF NOT EXISTS end_time   TIMESTAMPTZ,
        ADD COLUMN IF NOT EXISTS api_created_at TIMESTAMPTZ,
        ADD COLUMN IF NOT EXISTS api_last_modified TIMESTAMPTZ,
        ADD COLUMN IF NOT EXISTS entry_type TEXT,
        ADD COLUMN IF NOT EXISTS raw JSONB;
    }) { }

    DB.exec(%{
      CREATE INDEX IF NOT EXISTS idx_qbt_ts_job_date
        ON quickbooks_time_timesheets (quickbooks_time_jobsite_id, date);
    }) { }

    DB.exec(%{
      CREATE INDEX IF NOT EXISTS idx_qbt_ts_modified
        ON quickbooks_time_timesheets (api_last_modified);
    }) { }
  end
  
  def create_schema_migrations_table!
    DB.exec(%{
      CREATE TABLE IF NOT EXISTS schema_migrations (
        key TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ DEFAULT now()
      );
    }) { |res| LOG.debug [:created_table, :schema_migrations, res&.cmd_status] if res }
  end
  
  def apply_migrations!
    PGCreate::MIGRATIONS.each do |key, sql|
      DB.exec_params('SELECT 1 FROM schema_migrations WHERE key=$1 LIMIT 1', [key]) do |r|
        next if r.ntuples.positive?
        DB.exec(sql) { |res| LOG.debug [:migration_applied, key, res&.cmd_status] if res }
        DB.exec_params('INSERT INTO schema_migrations (key) VALUES ($1)', [key]) { |res| LOG.debug [:migration_recorded, key] if res }
      end
    end
  rescue => e
    LOG.error [:apply_migrations_failed, e.message]
  end

  def auth_url
    @auth.auth_url
  end

  def status
    @auth.status
  end

  # ===== ORCHESTRATION =====

  def authorized(auth)
    @auth = auth
    LOG.debug([:qbt_authorized, :begin_sync])


    sync_all_users! do |ok|
      next on_pipeline_error(:users) unless ok
  
      sync_all_jobcodes! do |ok|
        next on_pipeline_error(:jobcodes) unless ok
  
        backfill_all! do |ok|
          next on_pipeline_error(:timesheets) unless ok
  
          LOG.debug [:pipeline_complete]
          # kick off post queue if you have one
          # start_missive_post_loop!
        end
      end
    end
  end

    # wrapper: jobcodes with callback, sequential pages
  def sync_all_jobcodes!(&callback)
    get_last_sync_time(API_NAME) do |last_sync_time|
      sync_jobcodes_since(last_sync_time || EPOCH_8601) do |ok|
        callback&.call(ok)
      end
    end
  end

    # wrapper: jobcodes with callback, sequential pages
  def sync_all_jobcodes!(&callback)
    get_last_sync_time(API_NAME) do |last_sync_time|
      sync_jobcodes_since(last_sync_time || EPOCH_8601) do |ok|
        callback&.call(ok)
      end
    end
  end

  # add a callback path to your pager
  def sync_jobcodes_since(last_sync_time, page = 1, &callback)
    formatted = Time.parse(last_sync_time).utc.iso8601
    api_request("jobcodes?modified_since=#{formatted}&page=#{page}&limit=#{QBT_PAGE_LIMIT}") do |resp|
      ok = resp.is_a?(Hash)
      unless ok
        LOG.error [:jobcodes_fetch_failed, page]
        next callback&.call(false)
      end

      jobs = resp.dig('results', 'jobcodes') || {}
      jobs.each_value { |job| sync_job_to_db(job) }

      p resp['more']
      if resp['more']
        p 'yep'
        add_timeout(proc { sync_jobcodes_since(last_sync_time, page + 1, &callback) }, 0)
        next
      end

      update_sync_success(API_NAME, Time.now) do |_|
        callback&.call(true)
      end
    end
  rescue => e
    LOG.error [:sync_jobcodes_since_error, e.message]
    callback&.call(false)
  end

  # make update_sync_success accept an optional callback
  def update_sync_success(api_name, timestamp, &callback)
    sql = %{
      INSERT INTO api_sync_logs (api_name, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (api_name) DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, [api_name, timestamp]) do |result|
      LOG.debug [:sync_log_update, api_name, result.cmd_status]
      callback&.call(true)
    end
  end

  def on_pipeline_error(stage, err = nil)
    LOG.error [:pipeline_failed_at, stage, err]
    exit
    # optional: notify, set flags, or schedule a retry with backoff here
  end

  # ===== CORE HTTP =====

  def api_request(endpoint, &block)
    headers = { 'Authorization' => "Bearer #{@auth.token.access_token}" }
    url = "#{API_ENDPOINT}/#{endpoint}"

    NonBlockHTTP::Client::ClientSession.new.get(url, { headers: headers }, log_debug: true) do |response|
      next block.call(nil) unless response
      if response.code == 404 && endpoint.start_with?('timesheets')
        LOG.debug "404 for #{endpoint} (no entries)"
        next block.call({ 'results' => { 'timesheets' => {} } })
      end
      raise "QBT API #{response.code}: #{response.body}" unless response.code == 200

      parsed = JSON.parse(response.body) rescue nil
      next block.call(parsed || {})
    end
  rescue => e
    LOG.error [:api_request_failed, endpoint, e.message]
    block&.call(nil)
  end

  # ===== USERS =====

  def sync_all_users!(per_page: USERS_PER_PAGE, &callback)
    page = 1
    total = 0

    step = proc do
      q = { active: 'both', supplemental_data: 'yes', page: page, limit: QBT_PAGE_LIMIT }
      api_request("users?#{URI.encode_www_form(q)}") do |resp|
        resp ||= {}
        hydrate_users_from_supplemental!(resp)

        users = (resp.dig('results', 'users') || {}).values
        users.each { |u| @user_cache[u['id']] = u; upsert_user_row!(u) rescue nil }
        total += users.size
        LOG.debug [:users_page, page, :count, users.size, :total, total]

        p resp['more']
        if resp['more']
          p 'yep'
          page += 1
          add_timeout(step, API_RATE_LIMIT)
        else
          LOG.debug [:users_sync_done, :total, total]
          add_timeout(proc { callback&.call(true) }, API_RATE_LIMIT)
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
      u['id'], u['first_name'], u['last_name'], u['username'], u['email'],
      truthy?(u['active']),
      (Time.parse(u['last_modified']) rescue nil),
      (Time.parse(u['created']) rescue nil),
      JSON.dump(u)
    ]) { }
  rescue => e
    LOG.error [:user_upsert_failed, u&.dig('id'), e.message]
  end

  def hydrate_jobcodes_from_supplemental!(resp)
    jobs = (resp.dig('supplemental_data','jobcodes') || {})
    return if jobs.empty?
    jobs.each_value { |j| sync_job_to_db(j) }
  end
  
  def hydrate_users_from_supplemental!(resp)
    users = (resp.dig('supplemental_data','users') || {})
    return if users.empty?
    users.each_value do |u|
      @user_cache[u['id']] = u
      upsert_user_row!(u) rescue nil
    end
  end
  

  def get_user!(user_id)
    return @user_cache[user_id] if @user_cache[user_id]
    row = nil
    DB.exec_params('SELECT raw FROM quickbooks_time_users WHERE id=$1 LIMIT 1', [user_id]) { |r| row = r[0]['raw'] if r.ntuples.positive? } rescue nil
    return @user_cache[user_id] = (JSON.parse(row) rescue nil) if row
    # last resort: fetch single (should be rare)
    api_request("users?ids=#{user_id}") { |resp| u = resp.dig('results', 'users', user_id.to_s); @user_cache[user_id] = u if u }
    @user_cache[user_id]
  end

  # ===== JOBCODES (hydration only) =====

  def sync_all_jobcodes!(per_page: JOBS_PER_PAGE, &callback)
    page = 1
    total = 0
    step = proc do
      q = { active: 'both', page: page, limit: per_page }
      api_request("jobcodes?#{URI.encode_www_form(q)}") do |resp|
        resp ||= {}
        jobs = (resp.dig('results', 'jobcodes') || {}).values
        jobs.each { |j| sync_job_to_db(j) }
        total += jobs.size
        LOG.debug [:jobcodes_page, page, :count, jobs.size, :total, total]


      p resp['more']
        if resp['more']
          p 'yep'
          page += 1
          add_timeout(step, API_RATE_LIMIT)
        else
          LOG.debug [:jobcodes_sync_done, :total, total]
          update_sync_success(API_NAME, Time.now)
          add_timeout(proc { callback&.call(true) }, API_RATE_LIMIT)
        end
      end
    end
    step.call
  rescue => e
    LOG.error [:jobs_sync_failed, e.message]
    callback&.call(false)
  end

  def sync_job_to_db(job)
    DB.exec_params(
      'INSERT INTO quickbooks_time_jobs (
        id, parent_id, name, short_code, type, billable, billable_rate,
        has_children, assigned_to_all, required_customfields, filtered_customfielditems,
        active, last_modified, created
      )
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
       ON CONFLICT (id) DO UPDATE SET
         parent_id = EXCLUDED.parent_id,
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
        job['id'], job['parent_id'], job['name'], job['short_code'], job['type'],
        job['billable'], job['billable_rate'], job['has_children'], job['assigned_to_all'],
        job['required_customfields'].to_json, job['filtered_customfielditems'].to_json,
        job['active'], job['last_modified'], job['created']
      ]
    ) { }
  rescue => e
    LOG.error [:job_upsert_failed, job&.dig('id'), e.message]
  end

  # ===== TIMESHEETS (global sweep) =====

  def sync_all_timesheets!(since: EPOCH_TS, &callback)
    page = 1
    anchor = Time.now.utc
    touched = {}
    in_flight = 0

    step = proc do
      q = {
        modified_since: since.utc.iso8601,
        per_page: TS_PER_PAGE,
        page: page,
        supplemental_data: 'yes'
      }
      LOG.debug [:ts_sync_page, page, :since, q[:modified_since]]

      api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
        resp ||= {}
        hydrate_users_from_supplemental!(resp)
        hydrate_jobcodes_from_supplemental!(resp)

        rows = (resp.dig('results','timesheets') || {}).values
        if rows.empty?
          if in_flight.zero?
            update_timesheet_sync_success(anchor)
            # push overviews for everything touched
            return rebuild_touched_overviews!(touched.keys) { |ok| callback&.call(ok) }
          end
          next
        end

        in_flight += rows.size
        rows.each do |ts|
          upsert_timesheet_row!(ts) do |status, jid|
            touched[jid] = true if jid && status != :unchanged && status != :error
            in_flight -= 1
            if in_flight.zero?

      p resp['more']
              if resp['more']
                p 'yep'
                page += 1
                add_timeout(step, 0)
              else
                update_timesheet_sync_success(anchor)
                rebuild_touched_overviews!(touched.keys) { |ok| callback&.call(ok) }
              end
            end
          end
        end
      end
    end

    step.call
  end


  def backfill_all!(&callback)
    anchor = Time.now.utc
    touched = {}
    inflight = 0

    sweep_timesheets_modified_since(modified_since: (get_last_timesheet_sync || EPOCH_TS)) do |batch|
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

  def sweep_timesheets_modified_since(modified_since:, page: 1, per_page: TS_PER_PAGE, &on_page)
    q = {
      modified_since: modified_since.utc.iso8601,
      supplemental_data: 'yes',
      per_page: per_page,
      page: page
    }
    LOG.debug [:ts_sweep, q[:modified_since], :page, page]
    api_request("timesheets?#{URI.encode_www_form(q)}") do |resp|
      resp ||= {}
      hydrate_users_from_supplemental!(resp)
      rows = (resp.dig('results', 'timesheets') || {}).values
      on_page.call(rows || [])

      p resp['more']
      if resp['more']
        p 'yep'
        sweep_timesheets_modified_since(modified_since: modified_since, page: page + 1, per_page: per_page, &on_page)
      end
    end
  end

  # upsert + logging

  def upsert_timesheet_row!(ts, &callback)
    id   = ts['id']
    jid  = ts['jobcode_id']
    uid  = ts['user_id']
    date = ts['date']
    secs = ts['duration'].to_i
    notes = (ts['notes'] || '').strip
    st = (Time.parse(ts['start']) rescue nil)
    en = (Time.parse(ts['end'])   rescue nil)
    created = (Time.parse(ts['created']) rescue nil)
    modified = (Time.parse(ts['last_modified']) rescue nil)
    e_type = classify_entry(ts)
  
    hash = Digest::SHA1.hexdigest([uid, date, secs, notes, st&.to_i, en&.to_i].join('|'))
  
    DB.exec_params('SELECT last_hash FROM quickbooks_time_timesheets WHERE id=$1', [id]) do |r|
      new_rec = r.ntuples.zero?
      changed = new_rec || r[0]['last_hash'] != hash
  
      if new_rec
        DB.exec_params(%{
          INSERT INTO quickbooks_time_timesheets
            (id, quickbooks_time_jobsite_id, user_id, date, duration_seconds, notes,
             start_time, end_time, api_created_at, api_last_modified, entry_type, last_hash, raw)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
        }, [id, jid, uid, date, secs, notes, st, en, created, modified, e_type, hash, JSON.dump(ts)]) { }
        return callback&.call(:inserted, jid)
      end
  
      if changed
        DB.exec_params(%{
          UPDATE quickbooks_time_timesheets
             SET user_id=$1, date=$2, duration_seconds=$3, notes=$4,
                 start_time=$5, end_time=$6, api_created_at=$7, api_last_modified=$8,
                 entry_type=$9, last_hash=$10, raw=$11, updated_at=now()
           WHERE id=$12
        }, [uid, date, secs, notes, st, en, created, modified, e_type, hash, JSON.dump(ts), id]) { }
        return callback&.call(:updated, jid)
      end
  
      callback&.call(:unchanged, jid)
    end
  rescue => e
    LOG.error [:upsert_timesheet_row_failed, id, e.message]
    callback&.call(:error, nil)
  end
  

  def upsert_ts_and_log!(job_id, ts, &callback)
    tsid    = ts['id']
    user_id = ts['user_id']
    date    = ts['date']
    secs    = ts['duration'].to_i
    notes   = (ts['notes'] || '').strip
    hash    = Digest::SHA1.hexdigest([user_id, date, secs, notes].join('|'))

    DB.exec_params('SELECT last_hash FROM quickbooks_time_timesheets WHERE id=$1', [tsid]) do |res|
      new_rec = res.ntuples.zero?
      changed = new_rec || (res[0]['last_hash'] != hash)

      if new_rec
        DB.exec_params(%{
          INSERT INTO quickbooks_time_timesheets
            (id, quickbooks_time_jobsite_id, user_id, date, duration_seconds, notes, last_hash)
          VALUES ($1,$2,$3,$4,$5,$6,$7)
        }, [tsid, job_id, user_id, date, secs, notes, hash]) { }
        log_timesheet_event!(job_id, :created, ts) { callback&.call(true) }
        next
      end

      if changed
        DB.exec_params(%{
          UPDATE quickbooks_time_timesheets
          SET user_id=$1, date=$2, duration_seconds=$3, notes=$4, last_hash=$5, updated_at=now()
          WHERE id=$6
        }, [user_id, date, secs, notes, hash, tsid]) { }
        log_timesheet_event!(job_id, :updated, ts) { callback&.call(true) }
        next
      end

      callback&.call(false)
    end
  rescue => e
    LOG.error [:upsert_ts_failed, e.message]
    callback&.call(false)
  end

  def log_timesheet_event!(job_id, kind, ts, &callback)
    user = get_user!(ts['user_id'])
    tech = user ? "#{user['first_name']} #{user['last_name']}" : "User##{ts['user_id']}"
    emoji = (kind == :created ? "👷" : "✏️")
    dur   = fmt_hm(ts['duration'])
    note  = (ts['notes'] || '').strip
    md = +"#{emoji} **#{tech}** #{kind == :created ? 'logged' : 'updated'} #{dur} on #{ts['date']} (TSID `#{ts['id']}`)."
    md << "\n> _#{note}_" unless note.empty?
    color = TYPE_COLORS[classify_entry(ts)]
    append_post_markdown!(job_id, md, color: color) { |ok| callback&.call(ok) }
  end

  # ===== OVERVIEW =====

  def rebuild_touched_overviews!(job_ids, &callback)
    return callback&.call(true) if job_ids.nil? || job_ids.empty?
    i = 0
    step = proc do
      next callback&.call(true) if i >= job_ids.size
      jid = job_ids[i]; i += 1
      rebuild_overview!(jid) { add_timeout(step, API_RATE_LIMIT) }
    end
    step.call
  end

  def rebuild_overview!(job_id, &callback)
    ensure_overview_state(job_id) do |state|
      next callback&.call(false) unless state
      unbilled_totals(job_id) do |calc|
        status = state['status'] || 'unbilled'
        render_overview_markdown(job_id, calc, status: status, invoice_url: state['invoice_url']) do |md|
          old = state['overview_post_id']
          MISSIVE.channel_delete("posts/#{old}") { |_r| } if old  # keep thread tidy
  
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
                add_to_inbox: false,
                add_to_team_inbox: false
              }.compact
            }
  
            enqueue_post!(payload) do |ok, res|
              if ok
                post_id = (JSON.parse(res.body)['posts']['id'] rescue nil)
                if post_id
                  DB.exec_params(
                    'UPDATE quickbooks_time_overview_state SET overview_post_id=$1, total_unbilled_seconds=$2, updated_at=now() WHERE quickbooks_time_jobsite_id=$3',
                    [post_id, calc[:total_seconds], job_id]
                  ) { }
                end
              else
                LOG.error [:overview_upsert_failed]
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
  rescue => e
    LOG.error [:ensure_overview_state_failed, job_id, e.message]
    callback&.call(nil)
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
          (resp.dig('results', 'users') || {}).each { |_, u| @user_cache[u['id']] = u }
          compute_unbilled_totals(rows, &callback)
        end
      else
        compute_unbilled_totals(rows, &callback)
      end
    end
  rescue => e
    LOG.error [:unbilled_totals_failed, job_id, e.message]
    callback&.call({ total_seconds: 0, by_week_tech: {} })
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

  # ===== ADMIN ACTIONS (unchanged APIs) =====

  def admin_generate_invoice!(job_id, ts_ids:, invoice_id:, invoice_url:, admin_name:, &callback)
    DB.exec_params('UPDATE quickbooks_time_timesheets SET billed=true, billed_invoice_id=$1, updated_at=now() WHERE quickbooks_time_jobsite_id=$2 AND id = ANY($3::BIGINT[])',
                   [invoice_id, job_id, "{#{ts_ids.join(',')}}"]) { }
    md = "🧾 **#{admin_name}** generated invoice [`#{invoice_id}`](#{invoice_url}) for #{ts_ids.size} entries."
    append_post_markdown!(job_id, md, color: STATUS_COLORS['generated'], username: 'Billing') do |_|
      DB.exec_params('UPDATE quickbooks_time_overview_state SET status=$1, invoice_id=$2, invoice_url=$3, updated_at=now() WHERE quickbooks_time_jobsite_id=$4',
                     ['generated', invoice_id, invoice_url, job_id]) { }
      rebuild_overview!(job_id, &callback)
    end
  end

  def admin_mark_paid!(job_id, admin_name:, &callback)
    md = "💸 **#{admin_name}** marked invoice as **PAID**."
    append_post_markdown!(job_id, md, color: STATUS_COLORS['paid'], username: 'Billing') do |_|
      DB.exec_params('UPDATE quickbooks_time_overview_state SET status=$1, updated_at=now() WHERE quickbooks_time_jobsite_id=$2',
                     ['paid', job_id]) { }
      rebuild_overview!(job_id, &callback)
    end
  end

  def admin_link_qbo!(job_id, client_name:, admin_name:, &callback)
    md = "🔗 **#{admin_name}** linked jobsite to QBO client **#{client_name}**."
    append_post_markdown!(job_id, md, color: nil, username: 'Billing') { |_ok| rebuild_overview!(job_id, &callback) }
  end

  # ===== Missive posts (single path) =====

  def append_post_markdown!(job_id, markdown, color:, username: 'QuickBooks Time', &callback)
    get_full_job_name(job_id) do |job_name|
      body_preview = notif_body_from_markdown(markdown, limit: 180)
      payload = {
        posts: {
          references: [job_ref(job_id)],               # thread by reference
          username: username,
          conversation_subject: "QuickBooks Time: #{job_name}", # show jobsite name
          conversation_color: color,
          notification: {                               # Missive requires this for nice toast
            title: "QuickBooks Time • #{job_name}",
            body: body_preview
          },
          attachments: [
            { markdown: markdown, timestamp: Time.now.to_i, color: color }
          ],
          add_to_inbox: false,
          add_to_team_inbox: false
        }.compact
      }
      enqueue_post!(payload) { |ok, _res| callback&.call(ok) }
    end
  end
  

  # ===== helpers =====

  def get_last_timesheet_sync
    return nil
    ts = nil
    DB.exec_params('SELECT last_successful_sync FROM api_sync_logs WHERE api_name=$1 LIMIT 1', ['quickbooks_time_timesheets']) { |r|
      ts = Time.parse(r[0]['last_successful_sync']) if r.ntuples.positive?
    }
    ts
  rescue
    nil
  end

  def update_timesheet_sync_success(t)
    sql = %{
      INSERT INTO api_sync_logs (api_name, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (api_name) DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, ['quickbooks_time_timesheets', t]) { |res| LOG.debug [:timesheet_sync_mark, t, res.cmd_status] }
  end

  def job_ref(job_id)
    "qbt:job:#{job_id}"
  end

  def notif_body_from_markdown(md, limit: 140)
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
    t = (ts['type'] || ts['Type'] || '').to_s.downcase
    return :manual  if t == 'manual'
    return :regular if t == 'regular'
    has_start = ts['start'].to_s.strip != ''
    has_end   = ts['end'].to_s.strip   != ''
    has_start || has_end ? :regular : :manual
  rescue
    :regular
  end

  def get_full_job_name(job_id, &callback)
    name_parts = []
    fetch = ->(id) {
      DB.exec_params('SELECT name, parent_id FROM quickbooks_time_jobs WHERE id=$1', [id]) do |r|
        if r.ntuples.positive?
          row = r.first
          name_parts.unshift(row['name'])
          pid = row['parent_id'].to_i
          pid.positive? ? fetch.call(pid) : callback.call(name_parts.join(': '))
        else
          callback.call((name_parts.unshift("Jobsite ##{id}").join(': ')))
        end
      end
    }
    fetch.call(job_id)
  end

  def get_full_job_name_sync(job_id)
    stack = []
    current = job_id
    seen = 0
    while current && seen < 20
      seen += 1
      row = nil
      DB.exec_params('SELECT name, parent_id FROM quickbooks_time_jobs WHERE id=$1', [current]) { |r| row = r.first if r.ntuples.positive? }
      break unless row
      stack.unshift(row['name']); current = row['parent_id']&.to_i
      current = nil if current == 0
    end
    return stack.join(': ') unless stack.empty?
    "Jobsite ##{job_id}"
  rescue
    "Jobsite ##{job_id}"
  end

  def update_sync_success(api_name, timestamp)
    sql = %{
      INSERT INTO api_sync_logs (api_name, last_successful_sync)
      VALUES ($1, $2)
      ON CONFLICT (api_name) DO UPDATE SET last_successful_sync = EXCLUDED.last_successful_sync
    }
    DB.exec_params(sql, [api_name, timestamp]) { |r| LOG.debug [:api_sync_mark, api_name, r.cmd_status] }
  end

  def fmt_hm(seconds)
    h = seconds.to_i / 3600
    m = (seconds.to_i % 3600) / 60
    "#{h}h #{m}m"
  end

  def truthy?(v)
    v == true || v.to_s.downcase.start_with?('t', '1', 'y')
  end
end

QBT = QuickbooksTime.new unless defined?(QBT)
