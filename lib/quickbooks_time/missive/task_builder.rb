# frozen_string_literal: true

require 'time'
require 'date'
require 'tzinfo'
require 'cgi'
require_relative '../util/constants'
require_relative '../util/format'

class QuickbooksTime
  module Missive
    module TaskBuilder
      # --- helpers -----------------------------------------------------------

      def self.fmt_hm(t)
        return nil unless t
        t.strftime('%-I:%M%P') # 9:30am
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
        return nil if s.nil? || s.empty?
        Time.iso8601(s)
      rescue ArgumentError
        s2 = s.tr(' ', 'T') if s.include?(' ') && s =~ /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:/
        begin
          Time.iso8601(s2)
        rescue
          Time.parse(s).utc
        end
      end

      def self.compute_times(ts)
        start_s = ts['start_time'] || ts['start']
        end_s   = ts['end_time']   || ts['end']
        secs    = (ts['duration_seconds'] || ts['duration'] || 0).to_i
        entry   = (ts['type'] || ts[:type] || ts['entry_type']).to_s.downcase
        date_s  = ts['date'] || ts[:date]

        tzid = ts['user_tz'] || ts[:user_tz] || 'America/Vancouver'
        tz   = TZInfo::Timezone.get(tzid) rescue TZInfo::Timezone.get('UTC')

        LOG.debug([:compute_times_in, start_s: start_s, end_s: end_s, secs: secs, entry: entry, date: date_s, tzid: tzid])

        start_utc = parse_utc(start_s)
        end_utc   = parse_utc(end_s)

        LOG.debug([:parsed_utc, start_utc: start_utc, end_utc: end_utc])

        if start_utc.nil? && entry == 'manual' && date_s
          d = Date.parse(date_s) rescue nil
          LOG.debug([:fallback_date, date: d])
          if d
            start_local = tz.local_time(d.year, d.month, d.day, 9, 30, 0)
            start_utc = tz.local_to_utc(start_local)
            LOG.debug([:fallback_start_set, start_local: start_local, start_utc: start_utc])
          end
        end

        if end_utc.nil? && start_utc && secs.positive?
          end_utc = start_utc + secs
          LOG.debug([:derived_end_utc, end_utc: end_utc])
        end

        start_local = start_utc ? tz.utc_to_local(start_utc) : nil
        end_local   = end_utc   ? tz.utc_to_local(end_utc)   : nil

        LOG.debug([:compute_times_out, start_local: start_local, end_local: end_local])

        [start_local, end_local]
      end

      # --- builders (drop-in signatures) ------------------------------------

      # Title: "<icon> Tech — Job — 9:30am–5:50pm (7h 30m)"
      def self.build_task_title(ts)
        start_t, end_t = compute_times(ts)
        secs    = (ts_get(ts, :duration_seconds, :duration) || 0).to_i
        tech    = ts_get(ts, :tech, :user_name, :employee_name) || 'Unknown Tech'
        jobsite = ts_get(ts, :jobsite_name, :jobsite, :job_name, :job) || 'Unknown Job'

        time_s =
          if start_t && end_t
            "#{fmt_hm(start_t)}–#{fmt_hm(end_t)}"
          elsif start_t
            "#{fmt_hm(start_t)}–…"
          else
            'time tbd'
          end

        dur_s = secs.positive? ? fmt_dur(secs) : 'Clocked In'
        "#{icon_for(ts)} #{tech} — #{jobsite} — #{time_s} (#{dur_s})"
      end

      # Description: notes only (HTML <br> + bullets). Empty -> non-breaking space.
      def self.build_task_description(ts, _start_t, _end_t)
        notes = normalize_notes(ts)
        return "&nbsp;" if notes.empty?
        notes.map { |n| "&nbsp;&nbsp;• #{CGI.escapeHTML(n)}" }.join("<br>")
      end

      # --- state + payloads --------------------------------------------------

      def self.determine_task_state(ts)
        has_end_time = !(ts['end_time'].nil? || ts['end_time'].empty?) || !(ts['end'].nil? || ts['end'].empty?)
        has_duration = (ts['duration_seconds'] || ts['duration'] || 0).to_i.positive?
        (has_end_time || has_duration) ? 'closed' : 'in_progress'
      end

      def self.build_task_creation_payload(ts, references:, subject:, conversation_id: nil)
        start_t, end_t = compute_times(ts)
        state = determine_task_state(ts)
        due_date = end_t || (start_t ? start_t + 28_800 : Time.now + 28_800) # +8h

        links = conversation_id ? { links_to_conversation: [{ id: conversation_id }] } : {}

        {
          tasks: {
            references: references,
            subject: subject,
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
          subject: "QuickBooks Time: #{job_name}")
      end

      def self.build_user_task_creation_payload(ts)
        user_id  = ts['user_id']
        user_name = ts['user_name']
        build_task_creation_payload(ts,
          references: ["qbt:user:#{user_id}"],
          subject: "QuickBooks Time: #{user_name}")
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
