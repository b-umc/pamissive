# frozen_string_literal: true

require 'date'
require_relative '../missive/post_builder'
require_relative '../missive/queue'

class MissiveBackfiller
  def initialize(repo, months)
    @repo   = repo
    @months = months.to_i
  end

  def run
    return if @months <= 0

    since = Date.today << @months
    rows  = @repo.unposted_since(since)
    rows.sort_by! { |ts| QuickbooksTime::Missive::PostBuilder.compute_times(ts).last || Time.at(0) }
    rows.each do |ts|
      payloads = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
      Array(payloads).each do |payload|
        QuickbooksTime::Missive::Queue.enqueue_post(payload, timesheet_id: ts['id'])
      end
    end
  end
end
