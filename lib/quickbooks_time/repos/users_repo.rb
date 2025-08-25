# frozen_string_literal: true

require 'json'

class UsersRepo
  def initialize(db:)
    @db = db
  end

  def upsert(user)
    id = user['id'] || user[:id]
    last_modified = user['last_modified'] || user[:last_modified]
    tz_offset = user['tz_offset'] || user[:tz_offset]
    res = @db.exec_params('SELECT last_modified FROM quickbooks_time_users WHERE id=$1', [id])
    changed = res.ntuples.zero? || res[0]['last_modified'] != last_modified
    if changed
      @db.exec_params(
        'INSERT INTO quickbooks_time_users (id, first_name, last_name, username, email, active, last_modified, created, timezone_offset, raw)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
         ON CONFLICT (id) DO UPDATE SET
           first_name=EXCLUDED.first_name,
           last_name=EXCLUDED.last_name,
           username=EXCLUDED.username,
           email=EXCLUDED.email,
           active=EXCLUDED.active,
           last_modified=EXCLUDED.last_modified,
           created=EXCLUDED.created,
           timezone_offset=EXCLUDED.timezone_offset,
           raw=EXCLUDED.raw',
        [id, user['first_name'], user['last_name'], user['username'], user['email'], user['active'], last_modified, user['created'], tz_offset, user.to_json]
      )
    end
    changed
  end

  def name(id)
    res = @db.exec_params('SELECT first_name, last_name FROM quickbooks_time_users WHERE id=$1', [id])
    return nil if res.ntuples.zero?
    [res[0]['first_name'], res[0]['last_name']].compact.join(' ').strip
  end

  def users_without_conversation
    @db.exec('SELECT * FROM quickbooks_time_users WHERE missive_conversation_id IS NULL').to_a
  end

  def update_conversation_id(user_id, conversation_id)
    @db.exec_params('UPDATE quickbooks_time_users SET missive_conversation_id=$1 WHERE id=$2', [conversation_id, user_id])
  end
end
