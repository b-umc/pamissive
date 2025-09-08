# frozen_string_literal: true

require_relative 'services/users_syncer'
require_relative 'services/jobs_syncer'
require_relative 'services/timesheets_syncer'
require_relative 'services/timesheets_deleted_syncer'
require_relative 'services/timesheets_today_scanner'
require_relative 'services/timesheets_for_missive_creator'
require_relative 'services/missive_task_verifier'
require_relative 'services/summaries_refresher'
require_relative 'missive/client'
require_relative 'util/constants'
require_relative '../../nonblock_socket/select_controller'
require_relative '../shared/dt'

class QuickbooksTime
  include TimeoutInterface
  attr_reader :qbt, :repos, :timesheets_cursor, :users_cursor, :jobs_cursor, :timesheets_deleted_cursor, :queue, :limiter
  attr_accessor :auth

  POLL_METHODS = [
    :poll_last_modified,
    :poll_timesheets_today,
    :process_timesheets_for_missive_tasks,
    :reconcile_missive_task_states,
    :verify_missive_tasks,
    :drain_missive_queue
  ]

  POLL_INTERVAL = Constants::QBT_POLL_INTERVAL

  def initialize(qbt:, repos:, timesheets_cursor:, users_cursor:, jobs_cursor:, queue:, limiter:, auth: nil, timesheets_deleted_cursor: nil)
    @qbt = qbt
    @repos = repos
    @timesheets_cursor = timesheets_cursor
    @users_cursor = users_cursor
    @jobs_cursor = jobs_cursor
    @timesheets_deleted_cursor = timesheets_deleted_cursor
    @queue = queue
    @limiter = limiter
    @auth = auth
    @polling_started = false
    @auth_ready = !!auth&.status
    @html_ready = false

    @syncing_users = false
    @syncing_jobs = false
    @syncing_timesheets = false
    @syncing_timesheets_deleted = false

    # Track edge-triggered equality handling for last_modified heartbeat
    @lm_edge_trigger = {
      users: nil,
      jobs: nil,
      timesheets: nil,
      timesheets_deleted: nil
    }
    # Run a full summary rebuild only once after program launch.
    @did_initial_summary_rebuild = false
  end

  def auth=(auth)
    @auth = auth
    @auth_ready = !!auth&.status
    LOG.debug [:qbt_auth_ready, @auth_ready]
    try_start_polling
  end

  # Backward-compatibility: some callers may still invoke `authorized`.
  # We interpret that as the HTML/UI layer being ready to start polling.
  def authorized
    html_authorized!
  end

  # Explicitly signal that the HTML/session layer has been authorized and is ready.
  def html_authorized!
    @html_ready = true
    LOG.debug [:qbt_html_ready, @html_ready]
    try_start_polling
  end

  def auth_url
    auth&.auth_url || '#'
  end

  def status
    auth&.status || false
  end

  private

  def on_fail(stage)
    LOG.error [:quickbooks_time_poll_failed, stage]
  end

  def try_start_polling
    return if @polling_started
    unless @auth_ready && @html_ready
      unless @auth_ready
        LOG.info [:qbt_polling_waiting, :reason, :auth_token_missing]
      end
      unless @html_ready
        LOG.info [:qbt_polling_waiting, :reason, :html_not_authorized]
      end
      return
    end

    @polling_started = true
    LOG.info [:quickbooks_time_authorized_starting_poll_cycle]
    schedule_polls
  rescue => e
    LOG.error [:qbt_polling_start_error, e.class, e.message]
  end

  def schedule_polls
    stagger = POLL_INTERVAL / POLL_METHODS.size
    POLL_METHODS.each_with_index do |method_name, index|
      add_timeout(proc { send(method_name) }, stagger * (index + 1))
    end
  end

  def poll_last_modified
    # Heartbeat: check last_modified_timestamps and only sync changed entities
    qbt.last_modified_timestamps do |resp|
      unless resp
        add_timeout(method(:poll_last_modified), Constants::QBT_HEARTBEAT_INTERVAL)
        next
      end

      lm = resp.dig('results', 'last_modified_timestamps') || resp['last_modified_timestamps'] || {}
      LOG.debug [:qbt_last_modified_raw_remote, lm]
      begin
        users_remote = lm['users'] || lm[:users]
        jobs_remote  = lm['jobcodes'] || lm[:jobcodes]
        ts_remote    = lm['timesheets'] || lm[:timesheets]
        ts_del_remote = lm['timesheets_deleted'] || lm[:timesheets_deleted]

        users_local_ts, _ = users_cursor.read
        jobs_local_ts, _  = jobs_cursor.read
        ts_local_ts, _    = timesheets_cursor.read
        ts_del_local_ts, _ = timesheets_deleted_cursor ? timesheets_deleted_cursor.read : [Constants::QBT_EPOCH_ISO, 0]
        LOG.debug [:qbt_last_modified_raw_local, :users, users_local_ts, :jobs, jobs_local_ts, :timesheets, ts_local_ts, :timesheets_deleted, ts_del_local_ts]

        users_remote_t   = Shared::DT.parse_utc(users_remote, source: :qbt_input_time)
        jobs_remote_t    = Shared::DT.parse_utc(jobs_remote, source: :qbt_input_time)
        ts_remote_t      = Shared::DT.parse_utc(ts_remote, source: :qbt_input_time)
        ts_del_remote_t  = Shared::DT.parse_utc(ts_del_remote, source: :qbt_input_time)

        users_local_t    = Shared::DT.parse_utc(users_local_ts, source: :db_input_time)
        jobs_local_t     = Shared::DT.parse_utc(jobs_local_ts, source: :db_input_time)
        ts_local_t       = Shared::DT.parse_utc(ts_local_ts, source: :db_input_time)
        ts_del_local_t   = Shared::DT.parse_utc(ts_del_local_ts, source: :db_input_time)

        LOG.debug [:qbt_last_modified_compare,
          :users, users_remote_t&.iso8601, users_local_t&.iso8601,
          :jobs, jobs_remote_t&.iso8601, jobs_local_t&.iso8601,
          :timesheets, ts_remote_t&.iso8601, ts_local_t&.iso8601,
          :timesheets_deleted, ts_del_remote_t&.iso8601, ts_del_local_t&.iso8601]

        if users_remote_t && !@syncing_users && should_sync?(:users, users_remote_t, users_local_t)
          @syncing_users = true
          @lm_edge_trigger[:users] = users_remote_t
          UsersSyncer.new(qbt, repos, users_cursor).run do |ok|
            on_fail(:users) unless ok
            @syncing_users = false
          end
        end

        if jobs_remote_t && !@syncing_jobs && should_sync?(:jobs, jobs_remote_t, jobs_local_t)
          @syncing_jobs = true
          @lm_edge_trigger[:jobs] = jobs_remote_t
          JobsSyncer.new(qbt, repos, jobs_cursor).run do |ok|
            on_fail(:jobs) unless ok
            @syncing_jobs = false
          end
        end

        # If the remote timesheets timestamp is behind our stored cursor, our
        # cursor likely drifted into the future. Rewind to the remote value to
        # avoid starving syncs.
        begin
          if ts_remote_t && ts_local_t && (ts_remote_t < ts_local_t)
            LOG.warn [:qbt_timesheets_cursor_rewind, :from, ts_local_t.iso8601, :to, ts_remote_t.iso8601]
            # Reset the cursor id to 0 so ordering is driven solely by timestamp
            @timesheets_cursor.write(ts_remote_t.iso8601, 0)
            # Update our local snapshot used for comparisons below
            ts_local_t = ts_remote_t
          end
        rescue StandardError => e
          LOG.error [:qbt_timesheets_cursor_rewind_error, e.class, e.message]
        end

        if ts_remote_t && !@syncing_timesheets && should_sync?(:timesheets, ts_remote_t, ts_local_t)
          @syncing_timesheets = true
          @lm_edge_trigger[:timesheets] = ts_remote_t
          TimesheetsSyncer.new(qbt, repos, timesheets_cursor).backfill_all do |ok|
            on_fail(:timesheets) unless ok
            @syncing_timesheets = false
          end
        end

        # If timesheets are equal and we've already edge-triggered once for
        # this timestamp (i.e., should_sync? would skip), then trigger a full
        # summary rebuild only once after program launch.
        begin
          if ts_remote_t && ts_local_t && (ts_remote_t == ts_local_t)
            if @lm_edge_trigger[:timesheets] == ts_remote_t
              unless @did_initial_summary_rebuild
                LOG.info [:trigger_initial_summary_rebuild, ts_remote_t.iso8601]
                @did_initial_summary_rebuild = true
                SummariesRefresher.new(repos).rebuild_all do |ok|
                  LOG.info [:summary_rebuild_complete, ok]
                end
              end
            end
          end
        rescue => e
          LOG.error [:summary_rebuild_equal_skip_error, e.class, e.message]
        end

        # Apply the same rewind guard for the deleted stream
        begin
          if ts_del_remote_t && ts_del_local_t && (ts_del_remote_t < ts_del_local_t)
            LOG.warn [:qbt_timesheets_deleted_cursor_rewind, :from, ts_del_local_t.iso8601, :to, ts_del_remote_t.iso8601]
            @timesheets_deleted_cursor.write(ts_del_remote_t.iso8601, 0)
            ts_del_local_t = ts_del_remote_t
          end
        rescue StandardError => e
          LOG.error [:qbt_timesheets_deleted_cursor_rewind_error, e.class, e.message]
        end

        if timesheets_deleted_cursor && ts_del_remote_t && !@syncing_timesheets_deleted && should_sync?(:timesheets_deleted, ts_del_remote_t, ts_del_local_t)
          @syncing_timesheets_deleted = true
          @lm_edge_trigger[:timesheets_deleted] = ts_del_remote_t
          TimesheetsDeletedSyncer.new(qbt, repos, timesheets_deleted_cursor).run do |ok|
            on_fail(:timesheets_deleted) unless ok
            @syncing_timesheets_deleted = false
          end
        end
      rescue => e
        LOG.error [:qbt_last_modified_process_error, e.class, e.message]
      ensure
        add_timeout(method(:poll_last_modified), Constants::QBT_HEARTBEAT_INTERVAL)
      end
    end
  end

  # Decide if an entity should sync based on last_modified timestamps.
  # Triggers when remote > local, or once when remote == local (edge-trigger)
  def should_sync?(key, remote_t, local_t)
    return true if local_t.nil?
    return true if remote_t > local_t
    if remote_t == local_t
      if @lm_edge_trigger[key] != remote_t
        LOG.debug [:qbt_last_modified_equal_edge_trigger, key, remote_t.iso8601]
        return true
      else
        LOG.debug [:qbt_last_modified_equal_skip, key, remote_t.iso8601]
      end
    end
    false
  end

  # Faster cycle specifically for detecting in-progress timesheets today.
  def poll_timesheets_today
    TimesheetsTodayScanner.new(qbt, repos).run do |ok|
      on_fail(:timesheets_today) unless ok
      add_timeout(method(:poll_timesheets_today), Constants::QBT_TODAY_SCAN_INTERVAL)
    end
  end

  def process_timesheets_for_missive_tasks
    if Constants::MISSIVE_USE_TASKS
      TimesheetsForMissiveCreator.new(repos).run do
        add_timeout(method(:process_timesheets_for_missive_tasks), POLL_INTERVAL)
      end
    else
      # No-op when using summary-only mode
      add_timeout(method(:process_timesheets_for_missive_tasks), POLL_INTERVAL)
    end
  end

  def reconcile_missive_task_states
    if Constants::MISSIVE_USE_TASKS
      QuickbooksTime::TaskStateReconciler.new(repos).run do
        add_timeout(method(:reconcile_missive_task_states), POLL_INTERVAL)
      end
    else
      add_timeout(method(:reconcile_missive_task_states), POLL_INTERVAL)
    end
  end

  def verify_missive_tasks
    if Constants::MISSIVE_USE_TASKS
      QuickbooksTime::MissiveTaskVerifier.new(repos).run do
        add_timeout(method(:verify_missive_tasks), Constants::MISSIVE_VERIFY_INTERVAL)
      end
    else
      # Still checkpoint the summary queue periodically so it can drain
      begin
        QuickbooksTime::Missive::SummaryQueue.verify_completed!
      rescue StandardError
      end
      add_timeout(method(:verify_missive_tasks), Constants::MISSIVE_VERIFY_INTERVAL)
    end
  end

  def drain_missive_queue
    # Kick the Missive queue; it no-ops if already draining
    QuickbooksTime::Missive::Queue.drain(limiter: limiter, client: QuickbooksTime::Missive::Client.new, repo: repos.timesheets)
    add_timeout(method(:drain_missive_queue), POLL_INTERVAL)
  end
end
