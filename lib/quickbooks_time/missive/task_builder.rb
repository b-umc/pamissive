# frozen_string_literal: true

require 'time'
require 'date'
require 'tzinfo'
require 'cgi'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)
require_relative '../util/constants'
require_relative '../util/format'
require_relative '../../shared/dt'

class QuickbooksTime
  module Missive
    module TaskBuilder
      # --- helpers -----------------------------------------------------------

      def self.fmt_hm(t)
        return nil unless t
        t.strftime('%-I:%M%P') # 9:30am
      end

      def self.truthy?(v)
        case v
        when true then true
        when false, nil then false
        else
          s = v.to_s.strip.downcase
          %w[true t 1 yes y].include?(s)
        end
      end

      def self.fmt_dur(secs)
        secs = secs.to_i
        return '0m' if secs <= 0
        h = secs / 3600
        m = (secs % 3600) / 60
        m.zero? ? "#{h}h" : "#{h}h #{m}m"
      end

      def self.ts_get(ts, *keys)
        keys.each do |k|
          return ts[k] if ts.key?(k)
          ks = k.to_s
          return ts[ks] if ts.key?(ks)
        end
        nil
      end

      def self.normalize_notes(ts)
        raw = ts_get(ts, :notes, :notes_text, :notes_body, :note) || ts[:details] || ts['details']
        return [] if raw.nil?
        items = raw.is_a?(Array) ? raw : raw.to_s.split(/\r?\n+/)
        items.map { |n| n.to_s.strip }.reject(&:empty?)
      end

      def self.entry_type(ts)
        (ts['type'] || ts[:type] || ts['entry_type']).to_s.downcase
      end

      def self.icon_for(ts)
        case entry_type(ts)
        when 'manual', 'edited', 'edit' then '✏️'
        else '⏱'
        end
      end

      # --- time parsing / conversion ----------------------------------------

      def self.parse_utc(s)
        Shared::DT.parse_utc(s)
      end

      def self.compute_times(ts)
        start_s = ts['start_time'] || ts['start']
        end_s   = ts['end_time']   || ts['end']
        secs    = (ts['duration_seconds'] || ts['duration'] || 0).to_i
        entry   = (ts['type'] || ts[:type] || ts['entry_type']).to_s.downcase
        date_s  = ts['date'] || ts[:date]
        on_clk  = truthy?(ts['on_the_clock'] || ts[:on_the_clock])

        tzid = ts['user_tz'] || ts[:user_tz] || 'America/Vancouver'
        tz   = TZInfo::Timezone.get(tzid) rescue TZInfo::Timezone.get('UTC')

        #LOG.debug([:compute_times_in, start_s: start_s, end_s: end_s, secs: secs, entry: entry, date: date_s, tzid: tzid])

        start_utc = parse_utc(start_s)
        end_utc   = parse_utc(end_s)

        # Normalize to UTC before converting to the user's timezone.
        # QBT often returns ISO8601 with offsets (e.g., -07:00). Passing a
        # zoned time directly to utc_to_local would double-apply the offset.
        start_utc = start_utc&.getutc
        end_utc   = end_utc&.getutc

        #LOG.debug([:parsed_utc, start_utc: start_utc, end_utc: end_utc])

        guessed_start = false
        guessed_end   = false

        if start_utc.nil? && entry == 'manual' && date_s
          d = Date.parse(date_s) rescue nil
          #LOG.debug([:fallback_date, date: d])
          if d
            start_local = tz.local_time(d.year, d.month, d.day, 9, 30, 0)
            start_utc = tz.local_to_utc(start_local)
            guessed_start = true
            #LOG.error [:dt_guess_start_time, ts['id'], :reason, :manual_entry_no_start, :date, date_s, :tz, tzid, :chosen_start, start_local]
            #LOG.debug([:fallback_start_set, start_local: start_local, start_utc: start_utc])
          end
        end

        if end_utc.nil? && start_utc && secs.positive?
          end_utc = start_utc + secs
          #LOG.debug([:derived_end_utc, end_utc: end_utc])
        end

        # Fallback: Some closed entries from QBT can have on_the_clock=false
        # but no end time and zero duration temporarily. Use the last modified
        # timestamp as a best-effort end time for display purposes.
        if end_utc.nil? && start_utc && !on_clk && secs.to_i <= 0
          mod_s = ts['modified_qbt'] || ts[:modified_qbt] || ts['last_modified'] || ts[:last_modified]
          mod_utc = parse_utc(mod_s) rescue nil
          if mod_utc && mod_utc > start_utc
            end_utc = mod_utc
            guessed_end = true
            LOG.error [:dt_guess_end_time, ts['id'], :reason, :closed_no_end_or_duration, :start_utc, start_utc, :chosen_end_utc, end_utc]
          end
        end

        start_local = start_utc ? tz.utc_to_local(start_utc) : nil
        end_local   = end_utc   ? tz.utc_to_local(end_utc)   : nil

        #LOG.debug([:compute_times_out, start_local: start_local, end_local: end_local])

        # Mark guesses on the timesheet hash for presentation
        ts['__guessed_start'] = guessed_start if guessed_start
        ts['__guessed_end']   = guessed_end if guessed_end
        [start_local, end_local]
      end

      # --- builders (drop-in signatures) ------------------------------------

      def self.deleted?(ts)
        v = ts['deleted']
        v = ts[:deleted] if v.nil?
        v.to_s == 'true' || v == true || v == 't'
      end

      # Title: "<icon> Tech — Job — 9:30am–5:50pm (7h 30m)"
      def self.build_task_title(ts)
        start_t, end_t = compute_times(ts)
        secs    = (ts_get(ts, :duration_seconds, :duration) || 0).to_i
        tech    = ts_get(ts, :tech, :user_name, :employee_name) || 'Unknown Tech'
        jobsite = ts_get(ts, :jobsite_name, :jobsite, :job_name, :job) || 'Unknown Job'
        on_clk  = truthy?(ts['on_the_clock'] || ts[:on_the_clock])

        s_start = start_t && fmt_hm(start_t)
        s_end   = end_t && fmt_hm(end_t)
        s_start = "~#{s_start}" if s_start && ts['__guessed_start']
        s_end   = "~#{s_end}"   if s_end   && ts['__guessed_end']

        time_s =
          if start_t && end_t
            "#{s_start}–#{s_end}"
          elsif start_t
            "#{s_start}–…"
          else
            'time tbd'
          end

        # If we have both times, prefer computed duration even if secs is 0.
        if start_t && end_t
          dur_val = secs.positive? ? secs : (end_t.to_i - start_t.to_i)
          dur_s = fmt_dur(dur_val)
        else
          dur_s = on_clk ? 'Clocked In' : fmt_dur(secs)
        end
        base = "#{icon_for(ts)} #{tech} — #{jobsite} — #{time_s} (#{dur_s})"
        title = if deleted?(ts)
                  "**deleted** ~~#{base}~~"
                else
                  base
                end
        #tsid = ts_get(ts, :id)
        #tsid ? (title + title_id_tag(tsid.to_s)) : title
      end

      # Description: notes only (HTML <br> + bullets). Empty -> non-breaking space.
      def self.build_task_description(ts, _start_t, _end_t)
        notes = normalize_notes(ts)
        body = if notes.empty?
                 "&nbsp;".b
               elsif deleted?(ts)
                 notes.map { |n| "<s>&nbsp;&nbsp;• #{CGI.escapeHTML(n)}</s>" }.join("<br>")
               else
                 notes.map { |n| "&nbsp;&nbsp;• #{CGI.escapeHTML(n)}" }.join("<br>")
               end
        tsid = ts_get(ts, :id)
        tsid ? (body + title_id_tag(tsid.to_s)) : body
        #body
      end

      # --- id marker in title ----------------------------------------------
      # Prefer an HTML tag trick that tends to survive Missive's sanitizer.
      # Example: " <small><s>qbt:123456</s></small>" appended to the title.
      def self.title_id_tag(id)
        #"&nbsp; [comment]: # qbt:#{CGI.escapeHTML(id)}"
        "<p>----</p><p>[qbt:#{CGI.escapeHTML(id)}]"
      end

      # Try to extract an id from the title. Supports:
      # - data-qbt-ts="ID" (if attributes survive)
      # - visible tiny marker: qbt:ID inside the title
      # - legacy zero-width encoding fallback
      def self.extract_id_from_title(title)
        return nil unless title
        # 1) data attribute
        m = title.match(/data-qbt-ts=['"]([^'"<>]+)['"]/)
        return m[1] if m
        # 2) visible tiny marker
        m2 = title.match(/qbt:\s*([A-Za-z0-9_-]+)/)
        return m2[1] if m2
        # 3) zero-width legacy
        begin
          sent = "\u200D"
          zw0 = "\u200B"
          zw1 = "\u200C"
          i1 = title.index(sent)
          return nil unless i1
          i2 = title.index(sent, i1 + 1)
          return nil unless i2
          payload = title[i1 + 1...i2]
          return nil unless payload && payload.size.positive?
          bits = payload.chars.map { |c| c == zw1 ? '1' : (c == zw0 ? '0' : nil) }.join
          return nil if bits.nil? || bits.empty?
          bytes = bits.scan(/.{8}/)
          return nil if bytes.empty?
          decoded = bytes.map { |b| b.to_i(2).chr }.join
          decoded
        rescue StandardError
          nil
        end
      rescue StandardError
        nil
      end

      # --- state + payloads --------------------------------------------------

      def self.determine_task_state(ts)
        on_the_clock = truthy?(ts['on_the_clock'] || ts[:on_the_clock])
        begin
          start_t, end_t = compute_times(ts)
        rescue StandardError
          start_t = end_t = nil
        end

        desired = on_the_clock ? 'in_progress' : 'closed'
        desired = 'closed' if deleted?(ts)

        if desired == 'in_progress'
          reference_time = end_t || start_t
          if reference_time && (Time.now - reference_time) > (12 * 60 * 60)
            desired = 'closed'
          end
        end

        desired
      end

      def self.build_task_creation_payload(ts, references:, conversation_subject:, conversation_id: nil)
        start_t, end_t = compute_times(ts)
        state = determine_task_state(ts)
        due_date = end_t || (start_t ? start_t + 28_800 : Time.now + 28_800) # +8h

        links = conversation_id ? { links_to_conversation: [{ id: conversation_id }] } : {}

        {
          tasks: {
            references: references,
            conversation_subject: conversation_subject,
            title: build_task_title(ts),
            description: build_task_description(ts, start_t, end_t),
            due_at: due_date.to_i,
            subtask: true,
            team: ENV.fetch('QBT_TIMESHEETS_TEAM', nil),
            organization: ENV.fetch('MISSIVE_ORG_ID', nil)
          }.merge(links).compact
        }
      end

      def self.build_jobsite_task_creation_payload(ts)
        job_id   = ts['quickbooks_time_jobsite_id']
        job_name = ts['jobsite_name']
        build_task_creation_payload(ts,
          references: ["qbt:job:#{job_id}"],
          conversation_subject: "QuickBooks Time: #{job_name}")
      end

      def self.build_user_task_creation_payload(ts)
        user_id  = ts['user_id']
        user_name = ts['user_name']
        build_task_creation_payload(ts,
          references: ["qbt:user:#{user_id}"],
          conversation_subject: "QuickBooks Time: #{user_name}")
      end

      def self.build_task_update_payload(ts)
        start_t, end_t = compute_times(ts)
        state = determine_task_state(ts)
        due_date = end_t || (start_t ? start_t + 28_800 : Time.now + 28_800)
        {
          tasks: {
            title: build_task_title(ts),
            description: build_task_description(ts, start_t, end_t),
            state: state,
            due_at: due_date.to_i
          }
        }
      end
    end
  end
end
