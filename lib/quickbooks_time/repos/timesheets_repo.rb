# frozen_string_literal: true

require 'digest/sha1'

class TimesheetsRepo
  def initialize(db:)
    @db = db
  end

  # Inserts or updates a timesheet. Returns [changed, previous_post_id].
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

    start_t   = nil if start_t.nil? || start_t == ''
    end_t     = nil if end_t.nil? || end_t == ''
    created   = nil if created.nil? || created == ''
    modified  = nil if modified.nil? || modified == ''

    hash = Digest::SHA1.hexdigest([user_id, date, secs, notes, entry, start_t, end_t].join('|'))
    res = @db.exec_params('SELECT last_hash, missive_post_id FROM quickbooks_time_timesheets WHERE id=$1', [id])
    if res.ntuples.zero?
      @db.exec_params(
        'INSERT INTO quickbooks_time_timesheets (
           id, quickbooks_time_jobsite_id, user_id, date, duration_seconds,
           notes, last_hash, entry_type, missive_post_id, start_time, end_time, created_qbt, modified_qbt)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)',
        [id, job_id, user_id, date, secs, notes, hash, entry, nil, start_t, end_t, created, modified]
      )
      [true, nil]
    elsif res[0]['last_hash'] != hash
      old_post_id = res[0]['missive_post_id']
      @db.exec_params(
        'UPDATE quickbooks_time_timesheets
           SET quickbooks_time_jobsite_id=$1, user_id=$2, date=$3,
               duration_seconds=$4, notes=$5, last_hash=$6,
               entry_type=$7, start_time=$8, end_time=$9,
               created_qbt=$10, modified_qbt=$11, updated_at=now()
         WHERE id=$12',
        [job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, id]
      )
      [true, old_post_id]
    else
      [false, nil]
    end
  end

  def save_post_id(id, post_id)
    @db.exec_params('UPDATE quickbooks_time_timesheets SET missive_post_id=$1, updated_at=now() WHERE id=$2', [post_id, id])
  end

  def unposted_since(date)
    sql = <<~SQL
      SELECT t.*, j.name AS jobsite_name,
             (u.first_name || ' ' || u.last_name) AS user_name
      FROM quickbooks_time_timesheets t
      LEFT JOIN quickbooks_time_jobs j ON j.id = t.quickbooks_time_jobsite_id
      LEFT JOIN quickbooks_time_users u ON u.id = t.user_id
      WHERE t.date >= $1 AND t.missive_post_id IS NULL
    SQL
    res = @db.exec_params(sql, [date])
    res.map { |r| r }

  end
end

