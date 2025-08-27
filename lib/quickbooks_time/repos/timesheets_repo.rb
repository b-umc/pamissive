require 'digest/sha1'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

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
    on_clock  = !!(ts['on_the_clock'] || ts[:on_the_clock])

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
           notes, last_hash, entry_type, start_time, end_time, created_qbt, modified_qbt, missive_task_state, on_the_clock)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)',
        [id, job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, state, on_clock]
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
               created_qbt=$10, modified_qbt=$11, missive_task_state=$13, on_the_clock=$14, updated_at=now()
         WHERE id=$12',
        [job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, id, state, on_clock]
      )
      [true, old_task_ids]
    else
      [false, nil]
    end
  end

  def save_task_id(id, task_id, type, conversation_id: nil)
    task_column = type == :user ? 'missive_user_task_id' : 'missive_jobsite_task_id'
    convo_column = type == :user ? 'missive_user_task_conversation_id' : 'missive_jobsite_task_conversation_id'
    if conversation_id
      @db.exec_params(
        "UPDATE quickbooks_time_timesheets SET #{task_column}=$1, #{convo_column}=$2, updated_at=now() WHERE id=$3",
        [task_id, conversation_id, id]
      )
    else
      @db.exec_params(
        "UPDATE quickbooks_time_timesheets SET #{task_column}=$1, updated_at=now() WHERE id=$2",
        [task_id, id]
      )
    end
  end
  
  def update_task_state(id, state)
    @db.exec_params("UPDATE quickbooks_time_timesheets SET missive_task_state=$1, updated_at=now() WHERE id=$2", [state, id])
  end

  def set_user_task!(id, task_id, state, conversation_id = nil)
    save_task_id(id, task_id, :user, conversation_id: conversation_id)
    update_task_state(id, state)
  end

  def set_job_task!(id, task_id, state, conversation_id = nil)
    save_task_id(id, task_id, :jobsite, conversation_id: conversation_id)
    update_task_state(id, state)
  end

  def tasks_to_create_or_update(start_date = nil)
    sql = <<~SQL
      SELECT t.*, j.name AS jobsite_name,
             (u.first_name || ' ' || u.last_name) AS user_name,
             u.timezone_offset AS user_tz_offset
      FROM quickbooks_time_timesheets t
      LEFT JOIN quickbooks_time_jobs j ON j.id = t.quickbooks_time_jobsite_id
      LEFT JOIN quickbooks_time_users u ON u.id = t.user_id
    SQL

    where_clauses = []
    params = []

    if start_date
      where_clauses << "t.date >= $#{params.length + 1}"
      params << start_date
    end

    where_clauses << <<~SQL.strip
      (
        t.missive_user_task_id IS NULL
        OR t.missive_jobsite_task_id IS NULL
        OR t.missive_task_state IS DISTINCT FROM
          (
            CASE
              WHEN COALESCE(t.on_the_clock, (t.end_time IS NULL AND t.duration_seconds = 0))
                THEN 'in_progress'
              ELSE 'closed'
            END
          )
      )
    SQL

    sql << " WHERE #{where_clauses.join(' AND ')}" unless where_clauses.empty?
    sql << " ORDER BY t.date ASC, COALESCE(t.start_time, t.created_qbt) ASC"

    res = params.empty? ? @db.exec(sql) : @db.exec_params(sql, params)
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
    LOG.debug("paired_conversation called with task_id=#{task_id.inspect}, conversation_id=#{conversation_id.inspect}")

    if task_id
      task_id = task_id.to_s
      sql = <<~SQL
        SELECT missive_user_task_id, missive_jobsite_task_id,
               missive_user_task_conversation_id, missive_jobsite_task_conversation_id
        FROM quickbooks_time_timesheets
        WHERE missive_user_task_id = $1 OR missive_jobsite_task_id = $1
        LIMIT 1
      SQL
      LOG.debug("paired_conversation task_id SQL param=#{task_id}")
      res = @db.exec_params(sql, [task_id])
    elsif conversation_id
      conversation_id = conversation_id.to_s
      sql = <<~SQL
        SELECT missive_user_task_conversation_id, missive_jobsite_task_conversation_id
        FROM quickbooks_time_timesheets
        WHERE missive_user_task_conversation_id = $1 OR missive_jobsite_task_conversation_id = $1
        ORDER BY updated_at DESC
        LIMIT 1
      SQL
      LOG.debug("paired_conversation conversation_id SQL param=#{conversation_id}")
      res = @db.exec_params(sql, [conversation_id])
    else
      LOG.debug('paired_conversation called without task_id or conversation_id')
      return nil
    end

    LOG.debug("paired_conversation query returned ntuples=#{res.ntuples}")
    return nil if res.ntuples.zero?
    row = res[0]
    LOG.debug("paired_conversation row=#{row.inspect}")

    if task_id
      return row['missive_jobsite_task_conversation_id'] if row['missive_user_task_id'] == task_id
      return row['missive_user_task_conversation_id'] if row['missive_jobsite_task_id'] == task_id
    else
      return row['missive_jobsite_task_conversation_id'] if row['missive_user_task_conversation_id'] == conversation_id
      return row['missive_user_task_conversation_id'] if row['missive_jobsite_task_conversation_id'] == conversation_id
    end

    nil
  end
end
