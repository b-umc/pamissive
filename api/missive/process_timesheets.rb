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

DB = PG.connect(
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
)

ts_repo = TimesheetsRepo.new(db: DB)
limiter  = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)
client   = QuickbooksTime::Missive::Client.new

extend TimeoutInterface

rows = ts_repo.unposted_since(Date.new(1970, 1, 1))
idx = 0

process_next = proc do
  if idx >= rows.length
    DB.close
    exit
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
        DB.exec_params(
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
SelectController.run
