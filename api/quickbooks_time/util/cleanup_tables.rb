# frozen_string_literal: true

require 'pg'
require 'envkey' # Use dotenv for local development if needed

# --- Configuration ---
# This script assumes it's run in an environment where the PG_... environment
# variables are available (e.g., via `envkey-source` or a .env file).

# Database connection parameters from environment variables
DB_PARAMS = {
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
}.freeze

# --- Main Script ---

puts '--- Starting QuickbooksTime PG Table Cleanup ---'

begin
  # Establish a synchronous connection to the database
  conn = PG.connect(DB_PARAMS)
  puts '✅ Database connection successful.'

  # 1. Truncate the backfill status table to reset the sync process
  puts "-> Truncating 'quickbooks_time_backfill_status' table..."
  conn.exec('TRUNCATE TABLE quickbooks_time_backfill_status RESTART IDENTITY;')
  puts "   ...Done. The backfill queue is now empty."

  # 2. Drop the obsolete conversation mapping table
  puts "-> Dropping obsolete 'quickbooks_time_jobsite_conversations' table (if it exists)..."
  conn.exec('DROP TABLE IF EXISTS quickbooks_time_jobsite_conversations;')
  puts "   ...Done."

  puts "\n✅ Database cleanup complete."
  puts "You can now restart the main application to trigger a fresh sync for all jobs."

rescue PG::Error => e
  puts "\n❌ A database error occurred:"
  puts e.message
  puts "Please ensure the database is running and credentials are correct."
ensure
  # Always close the connection
  conn&.close
  puts '-> Database connection closed.'
end
