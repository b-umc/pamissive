# frozen_string_literal: true

require 'pg'
require 'date'

# Usage:
#   DRY_RUN=1 QBT_SICK_JOB_ID=123 QBT_OFFICE_JOB_ID=456 ruby script/reassign_jobsite_zero_timesheets.rb
#   DRY_RUN=0 QBT_SICK_JOB_ID=123 QBT_OFFICE_JOB_ID=456 ruby script/reassign_jobsite_zero_timesheets.rb

dry_run = (ENV.fetch('DRY_RUN', '1') != '0')
sick_id = ENV['QBT_SICK_JOB_ID']&.to_i
office_id = ENV['QBT_OFFICE_JOB_ID']&.to_i

conn = PG.connect(
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
)

rows = conn.exec(<<~SQL).to_a
  SELECT id, user_id, date, duration_seconds, notes
  FROM quickbooks_time_timesheets
  WHERE quickbooks_time_jobsite_id = 0
  ORDER BY date ASC, id ASC
SQL

puts "Found #{rows.length} timesheets with jobsite_id = 0"

updates = []
rows.each do |r|
  notes = (r['notes'] || '').strip
  if notes =~ /sick/i
    if sick_id && sick_id > 0
      updates << [r['id'], sick_id, 'sick']
    else
      puts "- TS #{r['id']} looks like SICK but QBT_SICK_JOB_ID is not set; skipping"
    end
  elsif notes =~ /office/i
    if office_id && office_id > 0
      updates << [r['id'], office_id, 'office']
    else
      puts "- TS #{r['id']} looks like OFFICE but QBT_OFFICE_JOB_ID is not set; skipping"
    end
  else
    puts "- TS #{r['id']} has notes='#{notes}' — no rule matched; leaving as-is"
  end
end

puts "Prepared #{updates.length} reassignments"

if dry_run
  puts "DRY_RUN=1 — not applying changes. Preview:"
  updates.each do |(id, jid, reason)|
    puts "UPDATE quickbooks_time_timesheets SET quickbooks_time_jobsite_id=#{jid}, updated_at=now() WHERE id=#{id}; -- #{reason}"
  end
  exit 0
end

# Apply updates in a single transaction
conn.exec('BEGIN')
begin
  updates.each do |(id, jid, reason)|
    conn.exec_params(
      'UPDATE quickbooks_time_timesheets SET quickbooks_time_jobsite_id=$1, updated_at=now() WHERE id=$2',
      [jid, id]
    )
  end
  conn.exec('COMMIT')
  puts "Applied #{updates.length} updates."
rescue => e
  conn.exec('ROLLBACK')
  warn "Error applying updates: #{e.class} #{e.message}"
  exit 1
ensure
  conn.close
end

