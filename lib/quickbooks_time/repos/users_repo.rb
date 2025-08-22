# frozen_string_literal: true

require 'json'

class UsersRepo
  def initialize(db:)
    @db = db
  end

  def upsert(user)
    id = user['id'] || user[:id]
    last_modified = user['last_modified'] || user[:last_modified]
    res = @db.exec_params('SELECT last_modified FROM quickbooks_time_users WHERE id=$1', [id])
    changed = res.ntuples.zero? || res[0]['last_modified'] != last_modified
    if changed
      @db.exec_params(
        'INSERT INTO quickbooks_time_users (id, first_name, last_name, username, email, active, last_modified, created, raw)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
         ON CONFLICT (id) DO UPDATE SET
           first_name=EXCLUDED.first_name,
           last_name=EXCLUDED.last_name,
           username=EXCLUDED.username,
           email=EXCLUDED.email,
           active=EXCLUDED.active,
           last_modified=EXCLUDED.last_modified,
           created=EXCLUDED.created,
           raw=EXCLUDED.raw',
        [id, user['first_name'], user['last_name'], user['username'], user['email'], user['active'], last_modified, user['created'], user.to_json]
      )
    end
    changed
  end

  def conversation_id(id)
    res = @db.exec_params('SELECT missive_conversation_id FROM quickbooks_time_users WHERE id=$1', [id])
    res.ntuples.zero? ? nil : res[0]['missive_conversation_id']
  end

  def set_conversation_id(id, convo_id)
    @db.exec_params('UPDATE quickbooks_time_users SET missive_conversation_id=$2 WHERE id=$1', [id, convo_id])
  end
end
