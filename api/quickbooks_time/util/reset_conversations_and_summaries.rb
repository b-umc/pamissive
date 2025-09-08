# frozen_string_literal: true

# Reset Missive conversation mappings and summary state using our
# non-blocking PG wrapper + token manager env.

require_relative '../../../env/token_manager'  # sets global DB (PGNonBlock)
require_relative '../../../nonblock_socket/select_controller'

puts '--- Reset Missive conversation mappings and summary state ---'

ops = [
  ['-> Clearing jobs.missive_conversation_id',
   'UPDATE quickbooks_time_jobs SET missive_conversation_id=NULL;'],
  ['-> Clearing users.missive_conversation_id',
   'UPDATE quickbooks_time_users SET missive_conversation_id=NULL;'],
  ['-> Truncating quickbooks_time_summary_state',
   'TRUNCATE TABLE quickbooks_time_summary_state;'],
  ['-> Clearing task linkage columns from quickbooks_time_timesheets', <<~SQL]
    UPDATE quickbooks_time_timesheets
    SET missive_user_task_id=NULL,
        missive_jobsite_task_id=NULL,
        missive_user_task_conversation_id=NULL,
        missive_jobsite_task_conversation_id=NULL,
        missive_task_state=NULL,
        missive_user_task_state=NULL,
        missive_jobsite_task_state=NULL;
  SQL
]

idx = 0
step = proc do
  if idx >= ops.length
    puts '✅ Reset complete.'
    return
  end
  msg, sql = ops[idx]
  idx += 1
  puts msg
  DB.exec(sql) { SelectController.add_timeout(step, 0) }
end

step.call
SelectController.run
