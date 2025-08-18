# # frozen_string_literal: true


require 'pg'
require 'envkey'

# --- Configuration ---
# This script assumes it's run in an environment where the PG_... environment
# variables are available (e.g., via `envkey-source` or a .env file).

DB_PARAMS = {
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
}.freeze

# List of all tables that are now obsolete and should be removed.
TABLES_TO_DROP = %w[
  quickbooks_time_backfill_status
  quickbooks_time_jobsite_conversations
  quickbooks_time_timesheet_posts
  quickbooks_time_timesheets
  quickbooks_time_overview_state
].freeze

# --- Main Script ---

puts '--- Starting Comprehensive QuickBooks Time PG Table Cleanup ---'

begin
  # Establish a synchronous connection to the database
  conn = PG.connect(DB_PARAMS)
  puts '✅ Database connection successful.'

  TABLES_TO_DROP.each do |table_name|
    puts "-> Dropping obsolete table '#{table_name}'..."
    # Use DROP TABLE IF EXISTS to safely remove the old tables.
    conn.exec("DROP TABLE IF EXISTS #{table_name} CASCADE;")
    puts "   ...Done. '#{table_name}' has been removed."
  end

  puts "\n✅ Database cleanup complete."
  puts "You can now restart the main application to create and use the new schema."

rescue PG::Error => e
  puts "\n❌ A database error occurred:"
  puts e.message
  puts "Please ensure the database is running and credentials are correct."
ensure
  # Always close the connection
  conn&.close
  puts '-> Database connection closed.'
end
