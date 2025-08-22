# frozen_string_literal: true

require 'pg'
require 'envkey' # Use dotenv for local development if needed

# --- Configuration ---
DB_PARAMS = {
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
}.freeze

puts '--- Backfilling Missive conversation IDs ---'

begin
  conn = PG.connect(DB_PARAMS)
  puts '✅ Database connection successful.'

  puts "-> Ensuring missive_conversation_id columns exist..."
  conn.exec(<<~SQL)
    ALTER TABLE quickbooks_time_jobs
      ADD COLUMN IF NOT EXISTS missive_conversation_id TEXT;
    ALTER TABLE quickbooks_time_users
      ADD COLUMN IF NOT EXISTS missive_conversation_id TEXT;
  SQL
  puts "   ...Done."

  puts "-> Backfilling quickbooks_time_jobs from quickbooks_time_jobsite_conversations..."
  conn.exec(<<~SQL)
    UPDATE quickbooks_time_jobs j
    SET missive_conversation_id = c.missive_conversation_id
    FROM quickbooks_time_jobsite_conversations c
    WHERE j.id = c.quickbooks_time_jobsite_id
      AND j.missive_conversation_id IS NULL;
  SQL
  puts "   ...Done."

  puts "\n✅ Backfill complete."
rescue PG::Error => e
  puts "\n❌ A database error occurred:"
  puts e.message
ensure
  conn&.close
  puts '-> Database connection closed.'
end
