# frozen_string_literal: true

require 'date'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../missive/client'
require_relative '../util/constants'
require_relative '../repos/timesheets_repo'
require_relative '../repos/jobs_repo'
require_relative '../repos/users_repo'
require_relative '../missive/task_builder'
require_relative '../../shared/dt'

class SummaryPoster
  def initialize(repos, client: QuickbooksTime::Missive::Client.new)
    @repos = repos
    @client = client
  end

  class << self
    def inflight
      @inflight ||= {}
    end

    def pending
      @pending ||= {}
    end
  end

  def post_job(job_id:, date:, notify: nil, &done)
    post_generic(type: :job, id: job_id, date: date, notify: notify, &done)
  end

  def post_user(user_id:, date:, notify: nil, &done)
    post_generic(type: :user, id: user_id, date: date, notify: notify, &done)
  end

  def post_generic(type:, id:, date:, notify: nil, &done)
    type = type.to_sym
    date_s = date.is_a?(Date) ? date.to_s : date.to_s

    # Coalesce concurrent posts per entity (type,id) to guarantee single post
    key = [type, id.to_s]
    if self.class.inflight[key]
      # Keep the latest intent; will re-run once current post completes
      self.class.pending[key] = { type: type, id: id, date: date_s, notify: notify }
      return done&.call(true)
    end
    self.class.inflight[key] = true

    single = Constants::MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION
    if type == :job
      if id.to_i <= 0
        LOG.warn [:summary_skip_invalid_job_id, id]
        self.class.inflight.delete([type, id.to_s])
        return done&.call(false)
      end
      @last_job_args = { job_id: id }
      conv_id = @repos.jobs.conversation_id(id)
      name    = @repos.jobs.name(id) || "Job #{id}"
      summary = if single
                  @repos.timesheets.all_time_summary_for_job(job_id: id)
                else
                  @repos.timesheets.daily_summary_for_job(job_id: id, date: date_s)
                end
      references = ["qbt:job:#{id}"]
      subject = "QuickBooks Time: #{name}"
    else
      @last_user_args = { user_id: id }
      conv_id = @repos.users.conversation_id(id) rescue nil
      name    = @repos.users.name(id) || "User #{id}"
      summary = if single
                  @repos.timesheets.all_time_summary_for_user(user_id: id)
                else
                  @repos.timesheets.daily_summary_for_user(user_id: id, date: date_s)
                end
      references = ["qbt:user:#{id}"]
      subject = "QuickBooks Time: #{name}"
    end

    md = markdown_for(summary: summary, type: type, date: date_s)
    return done&.call(false) unless md

    payload = build_payload(
      conv_id: conv_id,
      references: references,
      subject: subject,
      md: md,
      type: type,
      date_s: date_s,
      notify: notify
    )

    # If we already know the conversation, delete previous daily post first
    delete_prev = proc do |after|
      if conv_id
        begin
          state_date = Constants::MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION ? '0001-01-01' : date_s
          prev_id = @repos.timesheets.get_summary_post_id(conversation_id: conv_id, type: type, date: state_date)
        rescue => e
          LOG.warn [:summary_prev_lookup_error, e.class, e.message]
          prev_id = nil
        end
        if prev_id
          @client.delete_post(prev_id) do |_st, _hdrs, _body|
            begin
              @repos.timesheets.clear_summary_post_id(conversation_id: conv_id, type: type, date: state_date)
            rescue => e
              LOG.warn [:summary_prev_clear_error, e.class, e.message]
            ensure
              after.call
            end
          end
          return
        end
      end
      after.call
    end

    after_delete = proc do
      @client.create_post(payload) do |status, _hdrs, body|
        ok = (200..299).include?(status)
        if ok
          new_conv = body&.dig('posts', 'conversation')
          post_id  = body&.dig('posts', 'id')
          if new_conv && !conv_id
            begin
              if type == :job
                @repos.jobs.update_conversation_id(id, new_conv)
              else
                @repos.users.update_conversation_id(id, new_conv)
              end
              conv_id = new_conv
            rescue => e
              LOG.error [:summary_update_conv_id_error, e.class, e.message]
            end
          end
          if (conv_id || new_conv) && post_id
            begin
              conv_to_save = conv_id || new_conv
              state_date = Constants::MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION ? '0001-01-01' : date_s
              @repos.timesheets.save_summary_post_id(
                conversation_id: conv_to_save,
                type: type,
                date: state_date,
                post_id: post_id
              )
            rescue => e
              LOG.error [:summary_post_id_save_error, e.class, e.message]
            end
          end
        else
          LOG.error [:summary_post_failed, type, id, date_s, :status, status]
        end
        # Release inflight and run any pending update once
        self.class.inflight.delete(key)
        if (next_args = self.class.pending.delete(key))
          # Re-run once to converge to most recent state
          post_generic(**next_args) { done&.call(ok) }
        else
          done&.call(ok)
        end
      end
    end

    delete_prev.call(after_delete)
  end

  private

  def markdown_for(summary:, type:, date:)
    return nil unless summary && summary[:items]
    single = Constants::MISSIVE_SUMMARY_SINGLE_PER_CONVERSATION
    if type.to_sym == :user
      return user_markdown(summary: summary, date: date, single: single)
    else
      return job_markdown(summary: summary, date: date, single: single)
    end
  end

  def user_markdown(summary:, date:, single:)
    # Top: status line + this-week total
    # Middle: all-time totals by job (existing summary)
    # Bottom: event log of last 2 months with day and week separators
    lines = []
    title = single ? '**Timesheet Activity**' : "**User Daily Hours — #{date}**"
    lines << title

    # Drop all-time aggregated list for users (per request). We keep only
    # status (added above) and event log below.

    # Attempt to add status + event log if we can determine user_id from context stored in @last_user_args
    begin
      if @last_user_args && @last_user_args[:user_id]
        lines.unshift(*user_status_lines(@last_user_args[:user_id]))
        lines << "\n---"
        lines << user_event_log(@last_user_args[:user_id])
      end
    rescue => e
      LOG.warn [:user_summary_enrich_failed, e.class, e.message]
    end

    lines.join("\n")
  end

  def job_markdown(summary:, date:, single:)
    # When single summary per conversation is enabled, show:
    #  - On-the-clock users at this jobsite
    #  - All timesheets so far this week
    #  - Weekly totals from epoch to today
    if single && @last_job_args && @last_job_args[:job_id]
      job_id = @last_job_args[:job_id]
      lines = []
      lines << '**Timesheet Activity**'

      # On-the-clock list (newest start first)
      begin
        active = @repos.timesheets.job_active_clockins(job_id: job_id)
        lines << '**On the clock:**'
        if active.nil? || active.empty?
          lines << '- None'
        else
          active.sort_by { |r|
            (QuickbooksTime::Missive::TaskBuilder.compute_times(r).first || Time.at(0)).to_i
          }.reverse_each do |r|
            start_local, _ = QuickbooksTime::Missive::TaskBuilder.compute_times(r)
            since_s = start_local ? start_local.strftime('%a %b %-d, %-l:%M%P') : 'unknown'
            user_name = r['user_name'] || "User #{r['user_id']}"
            lines << "- #{user_name} since #{since_s}"
          end
        end
        lines << ''
      rescue => e
        LOG.warn [:job_summary_onclock_failed, e.class, e.message]
      end

      # This week's detailed timesheets
      begin
        today = Date.today
        week_start = today - (today.cwday - 1)
        rows = @repos.timesheets.job_timesheets_since(job_id: job_id, since_date: week_start)
        unless rows.empty?
          # Group by day
          by_day = {}
          rows.each do |r|
            d = Date.parse(r['date'].to_s) rescue today
            (by_day[d] ||= []) << r
          end
          days_sorted = by_day.keys.sort.reverse
          days_sorted.each do |d|
            dsecs = by_day[d].sum { |r| r['duration_seconds'].to_i }
            day_header = "- #{d.strftime('%a %Y-%m-%d')}: #{format('%.2f', dsecs / 3600.0)}h"
            day_header = "- **#{d.strftime('%a %Y-%m-%d')}: #{format('%.2f', dsecs / 3600.0)}h**" if dsecs > 8 * 3600
            lines << day_header
            by_day[d].reverse_each do |r|
              icon = (QuickbooksTime::Missive::TaskBuilder.entry_type(r) == 'manual') ? '✏️' : '⏱'
              st, en = QuickbooksTime::Missive::TaskBuilder.compute_times(r)
              user_name = r['user_name'] || "User #{r['user_id']}"
              dur_h = format('%.2f', r['duration_seconds'].to_i / 3600.0)
              time_s = if st && en
                "#{st.strftime('%-l:%M%P')}–#{en.strftime('%-l:%M%P')}"
              elsif st
                "#{st.strftime('%-l:%M%P')}–…"
              else
                'time tbd'
              end
              lines << "  - #{icon} #{user_name} • #{time_s} • #{dur_h}h"
            end
          end
          lines << ''
        end
      rescue => e
        LOG.warn [:job_summary_week_detail_failed, e.class, e.message]
      end

      # Weekly totals across all history
      begin
        weekly = @repos.timesheets.job_weekly_totals(job_id: job_id)
        unless weekly.empty?
          lines << '**Weekly totals (all time)**'
          weekly.reverse_each do |w|
            ws = w[:week_start] || w['week_start']
            secs = w[:seconds] || w['seconds']
            lines << "- Week of #{ws}: #{format('%.2f', secs.to_i / 3600.0)}h"
          end
        end
      rescue => e
        LOG.warn [:job_summary_weekly_totals_failed, e.class, e.message]
      end

      return lines.join("\n")
    end

    # Fallback to previous behavior when not single-mode: show daily by users
    lines = []
    header = 'Job Daily Hours'
    lines << "**#{header} — #{date}**"
    summary[:items].each do |it|
      hours = (it[:seconds].to_i / 3600.0)
      lines << "- #{it[:label]}: #{format('%.2f', hours)}h"
    end
    total_h = (summary[:total_seconds].to_i / 3600.0)
    lines << "**Total: #{format('%.2f', total_h)}h**"
    lines.join("\n")
  end

  def user_status_lines(user_id)
    # Compute on-clock status and this-week total
    since_date = (Date.today << 2)
    rows = @repos.timesheets.user_timesheets_since(user_id: user_id, since_date: since_date)
    # Determine any active clock-in row: prefer the latest start_time
    active = rows.select { |r| r['on_the_clock'].to_s == 't' || r['on_the_clock'] == true }.max_by { |r| (r['start_time'] || r['created_qbt'] || r['modified_qbt'] || Time.at(0)).to_s }
    status_line = if active
      start_local, _ = QuickbooksTime::Missive::TaskBuilder.compute_times(active)
      since_s = start_local ? start_local.strftime('%a %b %-d, %-l:%M%P') : 'unknown'
      "**Status:** On the clock since #{since_s}"
    else
      "**Status:** Off the clock"
    end

    # This week total (Mon..Sun)
    today = Date.today
    week_start = today - (today.cwday - 1)
    week_secs = rows.select { |r| Date.parse(r['date'].to_s) >= week_start }.sum { |r| r['duration_seconds'].to_i }
    week_line = "**This week:** #{format('%.2f', week_secs / 3600.0)}h"
    [status_line, week_line, '']
  end

  def user_event_log(user_id)
    since_date = (Date.today << 2)
    rows = @repos.timesheets.user_timesheets_since(user_id: user_id, since_date: since_date)
    return '_No recent activity._' if rows.empty?

    # Group by day and week (weeks start on Monday)
    by_day = {}
    by_week = Hash.new(0)
    rows.each do |r|
      d = Date.parse(r['date'].to_s)
      by_day[d] ||= []
      by_day[d] << r
      ws = d - (d.cwday - 1)
      by_week[ws] += r['duration_seconds'].to_i
    end

    # Build markdown newest -> oldest by week, then day
    days_sorted = by_day.keys.sort.reverse
    weeks_sorted = days_sorted.map { |d| d - (d.cwday - 1) }.uniq
    out = []

    weeks_sorted.each do |ws|
      wsecs = by_week[ws]
      warn = wsecs > 40 * 3600 ? ' ⚠️' : ''
      out << "**Week of #{ws}: #{format('%.2f', wsecs / 3600.0)}h#{warn}**"
      week_days = days_sorted.select { |d| (d - (d.cwday - 1)) == ws }
      week_days.each do |d|
        dsecs = by_day[d].sum { |r| r['duration_seconds'].to_i }
        dwarn = dsecs > 8 * 3600 ? ' ⚠️' : ''
        day_header = "- **#{d.strftime('%a %Y-%m-%d')}: #{format('%.2f', dsecs / 3600.0)}h#{dwarn}**"
        out << day_header
        by_day[d].reverse_each do |r|
          icon = (QuickbooksTime::Missive::TaskBuilder.entry_type(r) == 'manual') ? '✏️' : '⏱'
          st, en = QuickbooksTime::Missive::TaskBuilder.compute_times(r)
          jname = r['jobsite_name'] || "Job #{r['quickbooks_time_jobsite_id']}"
          dur_h = format('%.2f', r['duration_seconds'].to_i / 3600.0)
          time_s = if st && en
            "#{st.strftime('%-l:%M%P')}–#{en.strftime('%-l:%M%P')}"
          elsif st
            "#{st.strftime('%-l:%M%P')}–…"
          else
            'time tbd'
          end
          out << "  - #{icon} #{jname} • #{time_s} • #{dur_h}h"
        end
      end
      out << ''
    end
    out.join("\n")
  end

  def build_payload(conv_id:, references:, subject:, md:, type:, date_s:, notify: nil)
    team = ENV.fetch('QBT_POST_TEAM', nil)
    org  = ENV.fetch('MISSIVE_ORG_ID', nil)
    qbt_label      = ENV['QBT_LABEL_ID']
    jobsites_label = ENV['QBT_JOBSITES_LABEL_ID']
    users_label    = ENV['QBT_USERS_LABEL_ID']
    add_labels = [qbt_label]
    add_labels << (type.to_sym == :job ? jobsites_label : users_label)
    add_labels.compact!

    base = {
      username: 'Daily Summary',
      notification: (notify || default_notify(md, date_s)),
      attachments: [{ markdown: md, timestamp: Time.now.to_i }],
      add_to_inbox: false,
      add_to_team_inbox: false,
      team: team,
      organization: org,
      add_shared_labels: (add_labels if add_labels && !add_labels.empty?)
    }.compact

    if conv_id
      base.merge(conversation: conv_id)
    else
      base.merge(references: references, conversation_subject: subject)
    end
  end

  def default_notify(md, date_s)
    title = "Daily Hours • #{date_s}"
    body  = md.to_s.gsub(/[*_`>#]/, '').gsub(/\s+/, ' ').strip[0, 240]
    { title: title, body: body }
  end
end
