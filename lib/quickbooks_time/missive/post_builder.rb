# frozen_string_literal: true

require 'time'
require 'json' # Required for hx-vals
require_relative '../util/constants'
require_relative '../util/format'

# Helpers used by PostBuilder
class QuickbooksTime
  module Missive
    module Templates
      def self.timesheet_markdown(ts, start_t, end_t)
        user = ts['user_name'] || UserName.lookup(ts['user_id'])
        job  = ts['jobsite_name'] || JobName.lookup(ts['quickbooks_time_jobsite_id'] || ts['jobcode_id'])
        duration_hours = (ts['duration'] || ts[:duration] || ts['duration_seconds'] || 0).to_i / 3600.0
        flags = []
        flags << 'manual' if (ts['type'] || ts[:type] || ts['entry_type'])&.downcase == 'manual'
        flags << 'over 8h' if duration_hours > 8
        flag_str = flags.empty? ? '' : " **[#{flags.join(', ')}]**"
        lines = ["#{user} • #{job}#{flag_str}"]
        lines << "Shift: #{start_t.strftime('%-l:%M%P')} to #{end_t.strftime('%-l:%M%P')}" if start_t && end_t
        lines << "Duration: #{format('%.2f', duration_hours)}h"
        notes = ts['notes'] || ts[:notes]
        lines << "Notes: #{notes}" if notes && !notes.strip.empty?
        lines.join("\n")
      end
    end

    module JobName
      def self.lookup(job_id)
        "Job #{job_id}"
      end
    end

    module UserName
      def self.lookup(user_id)
        "User #{user_id}"
      end
    end

    module Colors
      def self.for(ts)
        duration = (ts['duration'] || ts[:duration] || ts['duration_seconds'] || 0).to_i
        return Constants::STATUS_COLORS['expired'] if (ts['type'] || ts[:type] || ts['entry_type'])&.downcase == 'manual'
        return Constants::STATUS_COLORS['overdue'] if duration > 28_800 # 8h
        Constants::STATUS_COLORS['unknown']
      end
    end

    module PostBuilder
      def self.compute_times(ts)
        secs    = (ts['duration'] || ts[:duration] || ts['duration_seconds'] || 0).to_i
        entry   = (ts['type'] || ts[:type] || ts['entry_type']).to_s.downcase
        start_s = ts['start'] || ts[:start] || ts['start_time'] || ts[:start_time]
        end_s   = ts['end'] || ts[:end] || ts['end_time'] || ts[:end_time]

        date    = ts['date'] || ts[:date]

        if (start_s.nil? || start_s.empty?) && entry == 'manual' && date
          start_s = "#{date}T09:30:00Z"
        end

        start_t = Time.parse(start_s) rescue nil
        end_t   = if end_s && !end_s.empty?
                    Time.parse(end_s) rescue nil
                  elsif start_t
                    start_t + secs
                  elsif date
                    Time.parse("#{date}T09:30:00Z") + secs rescue nil
                  end

        offset = (ts['tz_offset_minutes'] || ts[:tz_offset_minutes])&.to_i
        if offset
          start_t = start_t&.getlocal(offset * 60)
          end_t   = end_t&.getlocal(offset * 60)
        end

        [start_t, end_t]
      end

      def self.build_jobsite_post(ts)
        start_t, end_t = compute_times(ts)
        base_md = Templates.timesheet_markdown(ts, start_t, end_t)

        job_id    = ts['quickbooks_time_jobsite_id'] || ts['jobcode_id']
        job_name  = ts['jobsite_name'] || JobName.lookup(job_id)
        user_name = ts['user_name'] || UserName.lookup(ts['user_id'])

        team = ENV.fetch('QBT_POST_TEAM', nil)
        org  = ENV.fetch('MISSIVE_ORG_ID', nil) if team
        common = {
          username: 'QuickBooks Time',
          team: team,
          force_team: !team.nil?,
          organization: org,
          add_to_inbox: false,
          add_to_team_inbox: false
        }

        {
          posts: common.merge(
            references: ["qbt:job:#{job_id}"],
            conversation_subject: "QuickBooks Time: #{job_name}",
            notification: { title: "Timesheet • #{user_name}", body: ::Util::Format.notif_from_md(base_md) },
            attachments: [{ markdown: base_md, timestamp: end_t.to_i, color: Colors.for(ts) }]
          )
        }
      end

      def self.build_user_post(ts, _jobsite_conversation_id)
        start_t, end_t = compute_times(ts)
        base_md = Templates.timesheet_markdown(ts, start_t, end_t)

        user_id   = ts['user_id']
        job_name  = ts['jobsite_name'] || JobName.lookup(ts['quickbooks_time_jobsite_id'] || ts['jobcode_id'])
        user_name = ts['user_name'] || UserName.lookup(user_id)

        team = ENV.fetch('QBT_POST_TEAM', nil)
        org  = ENV.fetch('MISSIVE_ORG_ID', nil) if team
        common = {
          username: 'QuickBooks Time',
          team: team,
          force_team: !team.nil?,
          organization: org,
          add_to_inbox: false,
          add_to_team_inbox: false
        }

        {
          posts: common.merge(
            references: ["qbt:user:#{user_id}"],
            conversation_subject: "QuickBooks Time: #{user_name}",
            notification: { title: "Timesheet • #{job_name}", body: ::Util::Format.notif_from_md(base_md) },
            attachments: [{ markdown: base_md, timestamp: end_t.to_i, color: Colors.for(ts) }]
          )
        }
      end

      def self.overview(job_id, md, status_color)
        {
          posts: {
            references: ["qbt:job:#{job_id}"],
            username: 'Overview',
            conversation_subject: "QuickBooks Time: #{JobName.lookup(job_id)}",
            notification: { title: "QBT Overview • #{JobName.lookup(job_id)}", body: ::Util::Format.notif_from_md(md, 180) },
            attachments: [{ markdown: md, timestamp: Time.now.to_i, color: status_color }],
            add_to_inbox: false, add_to_team_inbox: false
          }
        }
      end
    end
  end
end
