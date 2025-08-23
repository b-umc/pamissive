#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pg'
require 'net/http'
require 'json'
require 'time'

DB = PG.connect(
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
)

MISSIVE_API_TOKEN = ENV.fetch('MISSIVE_JOBSITES_TOKEN', nil)
MISSIVE_API_URL = URI('https://public.missiveapp.com/v1/posts')

SQL = <<~SQL
  SELECT
      t.id AS timesheet_id,
      t.start_time,
      t.end_time,
      (t.entry_type = 'manual') AS is_manual,
      t.user_convo_link,
      u.id AS user_id,
      (u.first_name || ' ' || u.last_name) AS user_name,
      j.id AS jobsite_id,
      j.name AS jobsite_name
  FROM
      quickbooks_time_timesheets t
  JOIN
      quickbooks_time_users u ON t.user_id = u.id
  JOIN
      quickbooks_time_jobs j ON t.quickbooks_time_jobsite_id = j.id
  WHERE
      t.missive_user_post_id IS NULL;
SQL


def calculate_duration(start_time, end_time)
  return 0 unless start_time && end_time
  ((Time.parse(end_time) - Time.parse(start_time)) / 3600.0).round(2)
end

def post_to_missive(body, references)
  req = Net::HTTP::Post.new(MISSIVE_API_URL, {
    'Authorization' => "Bearer #{MISSIVE_API_TOKEN}",
    'Content-Type' => 'application/json'
  })
  req.body = { body: body, references: references }.to_json
  Net::HTTP.start(MISSIVE_API_URL.hostname, MISSIVE_API_URL.port, use_ssl: true) do |http|
    http.request(req)
  end
end

records = DB.exec(SQL).to_a

records.each do |record|
  sleep 1

  duration = calculate_duration(record['start_time'], record['end_time'])
  post_body_1 = <<~MD
    **User:** #{record['user_name']} at **Jobsite:** #{record['jobsite_name']}
    **Shift:** #{record['start_time']} to #{record['end_time']}
    **Duration:** #{duration}
    **Manually Added:** #{record['is_manual'] == 't' ? 'Yes' : 'No'}
    [Link to original conversation](#{record['user_convo_link']})
  MD

  res1 = post_to_missive(post_body_1, ["qbt:job:#{record['jobsite_id']}"])
  data1 = JSON.parse(res1.body) rescue {}
  conversation_id = data1.dig('posts', 'conversation') || data1.dig('conversation', 'id')
  post_id = data1.dig('posts', 'id') || data1['id']

  if conversation_id && post_id
    DB.exec_params('UPDATE quickbooks_time_jobs SET missive_conversation_id=$1 WHERE id=$2', [conversation_id, record['jobsite_id']])
    DB.exec_params('UPDATE quickbooks_time_timesheets SET missive_user_post_id=$1 WHERE id=$2', [post_id, record['timesheet_id']])
  end

  missive_conversation_url = "https://mail.missiveapp.com/#conversation/#{conversation_id}"
  post_body_2 = <<~MD
    **User:** #{record['user_name']} at **Jobsite:** #{record['jobsite_name']}
    **Shift:** #{record['start_time']} to #{record['end_time']}
    **Duration:** #{duration}
    **Manually Added:** #{record['is_manual'] == 't' ? 'Yes' : 'No'}
    [Link to jobsite conversation](#{missive_conversation_url})
  MD

  post_to_missive(post_body_2, ["qbt:user:#{record['user_id']}"])
end

DB.close
