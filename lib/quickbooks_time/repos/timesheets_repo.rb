# frozen_string_literal: true

require 'digest/sha1'

class TimesheetsRepo
  def initialize(db:)
    @db = db
  end

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

    hash = Digest::SHA1.hexdigest([user_id, date, secs, notes, entry, start_t, end_t].join('|'))
    res = @db.exec_params('SELECT last_hash FROM quickbooks_time_timesheets WHERE id=$1', [id])
    if res.ntuples.zero?
      @db.exec_params(
        'INSERT INTO quickbooks_time_timesheets (
           id, quickbooks_time_jobsite_id, user_id, date, duration_seconds,
           notes, last_hash, entry_type, start_time, end_time, created_qbt, modified_qbt)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)',
        [id, job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified]
      )
      true
    elsif res[0]['last_hash'] != hash
      @db.exec_params(
        'UPDATE quickbooks_time_timesheets
           SET quickbooks_time_jobsite_id=$1, user_id=$2, date=$3,
               duration_seconds=$4, notes=$5, last_hash=$6,
               entry_type=$7, start_time=$8, end_time=$9,
               created_qbt=$10, modified_qbt=$11, updated_at=now()
         WHERE id=$12',
        [job_id, user_id, date, secs, notes, hash, entry, start_t, end_t, created, modified, id]
      )
      true
    else
      false
    end
  end
end
