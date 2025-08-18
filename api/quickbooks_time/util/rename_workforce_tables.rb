# frozen_string_literal: true

require 'pg'
require 'envkey' # Assumes envkey is used for environment variables

# --- Configuration ---
# This script connects to your PostgreSQL database using environment variables.
DB_PARAMS = {
  dbname: 'ruby_jobsites',
  user: ENV.fetch('PG_JOBSITES_UN', nil),
  password: ENV.fetch('PG_JOBSITES_PW', nil),
  host: 'localhost'
}.freeze

# Defines the mapping of old table names to new table names.
TABLES_TO_RENAME = {
  'workforce_jobs' => 'quickbooks_time_jobs',
  'workforce_backfill_status' => 'quickbooks_time_backfill_status',
  'workforce_jobsite_conversations' => 'quickbooks_time_jobsite_conversations',
  'workforce_timesheet_posts' => 'quickbooks_time_timesheet_posts'
}.freeze

# --- Main Script ---

puts '--- Starting QuickBooks Time PG Table Rename Migration ---'

begin
  # Establish a synchronous connection to the database
  conn = PG.connect(DB_PARAMS)
  puts '✅ Database connection successful.'

  TABLES_TO_RENAME.each do |old_name, new_name|
    puts "-> Renaming table '#{old_name}' to '#{new_name}'..."
    # Use IF EXISTS to prevent errors if the script is run more than once.
    conn.exec("ALTER TABLE IF EXISTS #{old_name} RENAME TO #{new_name};")
    puts "   ...Done."
  end

  puts "\n✅ Database table renaming complete."
  puts "Your schema now matches the updated application code."

rescue PG::Error => e
  puts "\n❌ A database error occurred:"
  puts e.message
  puts "Please ensure the database is running and credentials are correct."
ensure
  # Always close the connection
  conn&.close
  puts '-> Database connection closed.'
end
