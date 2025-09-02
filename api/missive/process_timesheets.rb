#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pg'
require 'json'
require 'date'

require_relative '../../lib/quickbooks_time/repos/timesheets_repo'
require_relative '../../lib/quickbooks_time/missive/post_builder'
require_relative '../../lib/quickbooks_time/missive/client'
require_relative '../../lib/quickbooks_time/rate_limiter'
require_relative '../../lib/quickbooks_time/util/constants'
require_relative '../../nonblock_socket/select_controller'

# Provides a callable processor for posting historical timesheets to Missive
# without implicitly starting the SelectController event loop. This allows the
# main entrypoint (nonblock_HTML/loader.rb) to own the loop.
module QuickbooksTime
  module Missive
    module TimesheetProcessor
      extend TimeoutInterface

      module_function

      # Starts processing all unposted timesheets since the epoch.
      # If a DB connection is not provided, a new one is created and closed
      # when processing completes.
      #
      # @param db [PG::Connection, nil]
      def start!(db: nil)
        own_db = false
        conn = db
        unless conn
          conn = PG.connect(
            dbname: 'ruby_jobsites',
            user: ENV.fetch('PG_JOBSITES_UN', nil),
            password: ENV.fetch('PG_JOBSITES_PW', nil),
            host: 'localhost'
          )
          own_db = true
        end

        ts_repo = TimesheetsRepo.new(db: conn)
        limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)
        client  = QuickbooksTime::Missive::Client.new

        rows = ts_repo.unposted_since(Date.new(1970, 1, 1))
        idx = 0

        process_next = proc do
          if idx >= rows.length
            conn.close if own_db
            return
          end

          ts = rows[idx]
          idx += 1

          job_post, user_post = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)

          limiter.wait_until_allowed do
            client.post(job_post) do |res|
              ids = MISSIVE.parse_ids(res) rescue {}
              convo_id = ids[:conversation_id]
              post_id  = ids[:post_id]

              ts_repo.save_post_id(ts['id'], post_id) if post_id

              if convo_id
                conn.exec_params(
                  'INSERT INTO quickbooks_time_jobsite_conversations (quickbooks_time_jobsite_id, missive_conversation_id) VALUES ($1,$2) ON CONFLICT (quickbooks_time_jobsite_id) DO UPDATE SET missive_conversation_id=EXCLUDED.missive_conversation_id',
                  [ts['quickbooks_time_jobsite_id'], convo_id]
                )
                user_post[:posts][:conversation] = convo_id
              end

              limiter.wait_until_allowed do
                client.post(user_post) do |_res2|
                  add_timeout(process_next, 0)
                end
              end
            end
          end
        end

        process_next.call
      end
    end
  end
end

# If invoked directly, allow running the processor and owning the event loop.
# In the main app, require this file and call TimesheetProcessor.start! while
# SelectController is already running from nonblock_HTML/loader.rb
if $PROGRAM_NAME == __FILE__
  QuickbooksTime::Missive::TimesheetProcessor.start!
  SelectController.run
end
