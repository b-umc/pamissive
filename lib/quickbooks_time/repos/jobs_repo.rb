# frozen_string_literal: true

require 'json'

class JobsRepo
  def initialize(db:)
    @db = db
  end

  def upsert(job)
    id = job['id'] || job[:id]
    last_modified = job['last_modified'] || job[:last_modified]
    res = @db.exec_params('SELECT last_modified FROM quickbooks_time_jobs WHERE id=$1', [id])
    changed = res.ntuples.zero? || res[0]['last_modified'] != last_modified
    if changed
      @db.exec_params(
        'INSERT INTO quickbooks_time_jobs (
          id, parent_id, name, short_code, type, billable, billable_rate,
          has_children, assigned_to_all, required_customfields, filtered_customfielditems,
          active, last_modified, created)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
         ON CONFLICT (id) DO UPDATE SET
           parent_id=EXCLUDED.parent_id,
           name=EXCLUDED.name,
           short_code=EXCLUDED.short_code,
           type=EXCLUDED.type,
           billable=EXCLUDED.billable,
           billable_rate=EXCLUDED.billable_rate,
           has_children=EXCLUDED.has_children,
           assigned_to_all=EXCLUDED.assigned_to_all,
           required_customfields=EXCLUDED.required_customfields,
           filtered_customfielditems=EXCLUDED.filtered_customfielditems,
           active=EXCLUDED.active,
           last_modified=EXCLUDED.last_modified,
           created=EXCLUDED.created',
        [id, job['parent_id'], job['name'], job['short_code'], job['type'], job['billable'], job['billable_rate'], job['has_children'], job['assigned_to_all'], (job['required_customfields'] || []).to_json, (job['filtered_customfielditems'] || []).to_json, job['active'], last_modified, job['created']]
      )
    end
    changed
  end

  def conversation_id(id)
    res = @db.exec_params('SELECT missive_conversation_id FROM quickbooks_time_jobs WHERE id=$1', [id])
    res.ntuples.zero? ? nil : res[0]['missive_conversation_id']
  end

  def set_conversation_id(id, convo_id)
    @db.exec_params('UPDATE quickbooks_time_jobs SET missive_conversation_id=$2 WHERE id=$1', [id, convo_id])
  end
end
