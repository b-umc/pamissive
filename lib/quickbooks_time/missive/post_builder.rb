# frozen_string_literal: true

require_relative '../util/constants'
require_relative '../util/format'

# Placeholder helpers used by PostBuilder
class QuickbooksTime
  module Missive
    module Templates
      def self.timesheet_markdown(ts)
        "Timesheet #{ts['id']}"
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
      def self.for(_ts)
        Constants::STATUS_COLORS['unknown']
      end
    end

    module PostBuilder
      def self.timesheet_event(ts)
        md = Templates.timesheet_markdown(ts)
        {
          posts: {
            references: ["qbt:job:#{ts['jobcode_id']}"],
            username: 'QuickBooks Time',
            conversation_subject: "QuickBooks Time: #{JobName.lookup(ts['jobcode_id'])}",
            notification: { title: "Timesheet • #{UserName.lookup(ts['user_id'])}",
                            body: ::Util::Format.notif_from_md(md) },
            attachments: [{ markdown: md, timestamp: Time.now.to_i, color: Colors.for(ts) }],
            add_to_inbox: false, add_to_team_inbox: false
          }
        }
      end

      def self.overview(job_id, md, status_color)
        {
          posts: {
            references: ["qbt:job:#{job_id}"],
            username: 'Overview',
            conversation_subject: "QuickBooks Time: #{JobName.lookup(job_id)}",
            notification: { title: "QBT Overview • #{JobName.lookup(job_id)}",
                            body: ::Util::Format.notif_from_md(md, 180) },
            attachments: [{ markdown: md, timestamp: Time.now.to_i, color: status_color }],
            add_to_inbox: false, add_to_team_inbox: false
          }
        }
      end
    end
  end
end
