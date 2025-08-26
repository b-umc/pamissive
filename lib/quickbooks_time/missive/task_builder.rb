# frozen_string_literal: true

require 'time'
require_relative '../util/constants'
require_relative '../util/format'

class QuickbooksTime
  module Missive
    module TaskBuilder
      def self.compute_times(ts)
        start_s = ts['start_time'] || ts['start']
        end_s   = ts['end_time'] || ts['end']
        secs    = (ts['duration_seconds'] || ts['duration'] || 0).to_i
        entry   = (ts['type'] || ts[:type] || ts['entry_type']).to_s.downcase
        date    = ts['date'] || ts[:date]

        # Parse times from DB (which are UTC)
        start_t = Time.parse(start_s) rescue nil
        
        # Only apply 9:30 AM default for manual entries that have no start time
        if start_t.nil? && entry == 'manual' && date
          start_t = Time.parse("#{date}T09:30:00Z")
        end

        end_t   = Time.parse(end_s) rescue nil if end_s && !end_s.empty?
        end_t ||= start_t + secs if start_t && secs.positive?

        # Get user's timezone offset from the joined user table data (it's in seconds)
        offset = ts['user_tz_offset']&.to_i
        if offset && start_t
          start_t = start_t.getlocal(offset)
          end_t = end_t&.getlocal(offset)
        end

        [start_t, end_t]
      end

      def self.build_task_title(ts)
        user = "#{ts['user_name']}"
        job  = "#{ts['jobsite_name']}"
        duration_seconds = (ts['duration'] || ts[:duration] || ts['duration_seconds'] || 0).to_i
        
        if duration_seconds.positive?
          duration_hours = duration_seconds / 3600.0
          "#{user} • #{job} • #{format('%.2f', duration_hours)}h"
        else
          "#{user} • #{job} • (Clocked In)"
        end
      end

      def self.build_task_description(ts, start_t, end_t)
        notes = ts['notes'] || ts[:notes]
        lines = []
        if start_t
          #lines << "Shift on #{start_t.strftime('%Y-%m-%d')}: #{start_t.strftime('%-l:%M%P')} to #{end_t&.strftime('%-l:%M%P') || 'Now'}"
					lines << "Shift: #{start_t.strftime('%-l:%M%P')} to #{end_t&.strftime('%-l:%M%P') || 'Now'}"
        end
        lines << "Notes: #{notes}" if notes && !notes.strip.empty?
        lines.join("<br>")
      end

      def self.determine_task_state(ts)
        has_end_time = !(ts['end_time'].nil? || ts['end_time'].empty? || ts['end'].nil? || ts['end'].empty?)
        has_duration = (ts['duration_seconds'] || ts['duration'] || 0).to_i.positive?
        
        (has_end_time || has_duration) ? 'closed' : 'in_progress'
      end

      def self.build_task_creation_payload(ts, references:, subject:, conversation_id: nil)
        start_t, end_t = compute_times(ts)
        state = determine_task_state(ts)
        due_date = end_t || (start_t ? start_t + 28800 : Time.now + 28800)

        links = conversation_id ? { links_to_conversation: [{ id: conversation_id }] } : {}

        {
          tasks: {
            references: references,
            conversation_subject: subject,
            title: build_task_title(ts),
            description: build_task_description(ts, start_t, end_t),
            due_at: due_date.to_i,
            subtask: true,
						state: state,
            team: ENV.fetch('QBT_TIMESHEETS_TEAM', nil),
            organization: ENV.fetch('MISSIVE_ORG_ID', nil)
          }.merge(links).compact
        }
      end

      def self.build_jobsite_task_creation_payload(ts)
        job_id = ts['quickbooks_time_jobsite_id']
        job_name = ts['jobsite_name']
        convo_id = ts['jobsite_conversation_id']
        build_task_creation_payload(ts, references: ["qbt:job:#{job_id}"], subject: "QuickBooks Time: #{job_name}", conversation_id: convo_id)
      end

      def self.build_user_task_creation_payload(ts)
        user_id = ts['user_id']
        user_name = ts['user_name']
        convo_id = ts['user_conversation_id']
        build_task_creation_payload(ts, references: ["qbt:user:#{user_id}"], subject: "QuickBooks Time: #{user_name}", conversation_id: convo_id)
      end

      def self.build_task_update_payload(ts)
        start_t, end_t = compute_times(ts)
        state = determine_task_state(ts)
        due_date = end_t || (start_t ? start_t + 28800 : Time.now + 28800)
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
