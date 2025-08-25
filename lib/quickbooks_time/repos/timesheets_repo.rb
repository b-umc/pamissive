# frozen_string_literal: true

require 'digest/sha1'

class TimesheetsRepo
  def initialize(db:)
    @db = db
  end

  # Inserts or updates a timesheet. Returns [changed, previous_task_ids].
  def upsert(ts)
    id        = ts['id'] || ts[:id]
    job_id    = ts['jobcode_id'] || ts[:jobcode_id]
    user_id   = ts['user_id'] || ts[:user_id]
    date      = ts['date'] || ts[:date]
    secs      = (ts['duration'] || ts[:duration]).to_i
    notes     = (ts['notes'] || ts[:notes] || '').strip
    entry     = ts['type'] || ts[:type]
    start_t   = ts['start'] || ts[:start]
    end_t     = ts['end'] || ts[:end]
    created   = ts['created'] || ts[:created]
    modified  = ts['last_modified'] || ts[:last_modified]
    state     = QuickbooksTime::Missive::TaskBuilder.determine_task_state(ts)

    start_t   = nil if start_t.nil? || start_t == ''
    end_t     = nil if end_t.nil? || end_t == ''
    created   = nil if created.nil? || created == ''
    modified  = nil if modified.nil? || modified == ''

    hash = Digest::SHA1.hexdigest([user_id, date, secs, notes, entry, start_t, end_t].join('|'))
    res = @db.exec_params('SELECT last_hash, missive_user_task_id, missive_jobsite_task_id FROM quickbooks_time_timesheets WHERE id=$1', [id])
    if res.ntuples.zero?
      @db.exec_params(
        'INSERT INTO quickbooks_time_timesheets (
           id, quickbooks_time_jobsite_id, user_id, date, duration_seconds,
           notes, last_hash, entry_type, start_time, end_time, created_qbt, modified_qbt, missive_task_state)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)',
        [id, job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, state]
      )
      [true, {}]
    elsif res[0]['last_hash'] != hash
      old_task_ids = {
        user_task_id: res[0]['missive_user_task_id'],
        jobsite_task_id: res[0]['missive_jobsite_task_id']
      }
      @db.exec_params(
        'UPDATE quickbooks_time_timesheets
           SET quickbooks_time_jobsite_id=$1, user_id=$2, date=$3,
               duration_seconds=$4, notes=$5, last_hash=$6,
               entry_type=$7, start_time=$8, end_time=$9,
               created_qbt=$10, modified_qbt=$11, missive_task_state=$13, updated_at=now()
         WHERE id=$12',
        [job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, id, state]
      )
      [true, old_task_ids]
    else
      [false, nil]
    end
  end

  def save_task_id(id, task_id, type)
    column = type == :user ? 'missive_user_task_id' : 'missive_jobsite_task_id'
    @db.exec_params("UPDATE quickbooks_time_timesheets SET #{column}=$1, updated_at=now() WHERE id=$2", [task_id, id])
  end
  
  def update_task_state(id, state)
    @db.exec_params("UPDATE quickbooks_time_timesheets SET missive_task_state=$1, updated_at=now() WHERE id=$2", [state, id])
  end

  def tasks_to_create_or_update(date)
    sql = <<~SQL
      SELECT t.*, j.name AS jobsite_name,
             (u.first_name || ' ' || u.last_name) AS user_name,
             u.missive_conversation_id AS user_conversation_id,
             j.missive_conversation_id AS jobsite_conversation_id,
             u.timezone_offset AS user_tz_offset
      FROM quickbooks_time_timesheets t
      LEFT JOIN quickbooks_time_jobs j ON j.id = t.quickbooks_time_jobsite_id
      LEFT JOIN quickbooks_time_users u ON u.id = t.user_id
      WHERE t.date >= $1 AND (
        t.missive_user_task_id IS NULL OR 
        t.missive_jobsite_task_id IS NULL OR
        t.missive_task_state != (CASE WHEN (t.end_time IS NOT NULL OR t.duration_seconds > 0) THEN 'closed' ELSE 'in_progress' END)
      )
      ORDER BY t.date ASC, t.start_time ASC
    SQL
    res = @db.exec_params(sql, [date])
    res.map { |r| r }
  end

  # Returns the paired conversation ID for a given task or conversation.
  # If +task_id+ is provided, it will look up the timesheet that owns that
  # task and return the conversation ID for the opposite side (user vs
  # jobsite). If +conversation_id+ is provided, the method returns the
  # conversation ID for the other party of the most recent timesheet related
  # to that conversation.
  #
  # @param task_id [String] Missive task ID from the comment.
  # @param conversation_id [String] Missive conversation ID.
  # @return [String, nil] The paired conversation ID or nil if none found.
  def paired_conversation(task_id: nil, conversation_id: nil)
    if task_id
      res = @db.exec_params(<<~SQL, [task_id])
        SELECT t.missive_user_task_id, t.missive_jobsite_task_id,
               u.missive_conversation_id AS user_conversation_id,
               j.missive_conversation_id AS jobsite_conversation_id
        FROM quickbooks_time_timesheets t
        LEFT JOIN quickbooks_time_users u ON u.id = t.user_id
        LEFT JOIN quickbooks_time_jobs j ON j.id = t.quickbooks_time_jobsite_id
        WHERE t.missive_user_task_id = $1 OR t.missive_jobsite_task_id = $1
        LIMIT 1
      SQL
    elsif conversation_id
      res = @db.exec_params(<<~SQL, [conversation_id])
        SELECT t.missive_user_task_id, t.missive_jobsite_task_id,
               u.missive_conversation_id AS user_conversation_id,
               j.missive_conversation_id AS jobsite_conversation_id
        FROM quickbooks_time_timesheets t
        LEFT JOIN quickbooks_time_users u ON u.id = t.user_id
        LEFT JOIN quickbooks_time_jobs j ON j.id = t.quickbooks_time_jobsite_id
        WHERE u.missive_conversation_id = $1 OR j.missive_conversation_id = $1
        ORDER BY t.updated_at DESC
        LIMIT 1
      SQL
    else
      return nil
    end

    return nil if res.ntuples.zero?
    row = res[0]

    if task_id
      return row['jobsite_conversation_id'] if row['missive_user_task_id'] == task_id.to_s
      return row['user_conversation_id'] if row['missive_jobsite_task_id'] == task_id.to_s
    else
      return row['jobsite_conversation_id'] if row['user_conversation_id'] == conversation_id.to_s
      return row['user_conversation_id'] if row['jobsite_conversation_id'] == conversation_id.to_s
    end

    nil
  end
end
