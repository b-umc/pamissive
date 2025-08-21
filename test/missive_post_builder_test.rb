# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/quickbooks_time/missive/post_builder'

class MissivePostBuilderTest < Minitest::Test
  def test_timesheet_event_builds_post
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'duration' => 3600,
      'date' => '2024-01-01',
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    job_post = posts.find { |p| p[:posts][:references] == ['qbt:job:2'] }
    tech_post = posts.find { |p| p[:posts][:references] == ['qbt:user:3', 'qbt:job:2'] }
    md_job = job_post[:posts][:attachments][0][:markdown]
    md_tech = tech_post[:posts][:attachments][0][:markdown]

    assert_equal 'QuickBooks Time', job_post[:posts][:username]
    assert_includes md_job, '**User:** John Doe'
    assert_includes md_job, '**Job:** Main Site'
    assert_includes md_job, '(ref:qbt:user:3,qbt:job:2)'
    assert_includes md_tech, '(ref:qbt:job:2)'
    assert_equal Constants::STATUS_COLORS['unknown'], job_post[:posts][:attachments][0][:color]
    assert_match(/John Doe/, job_post[:posts][:notification][:title])
    assert_match(/Main Site/, job_post[:posts][:conversation_subject])
  end

  def test_timesheet_event_includes_timezone
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'start' => '2024-01-01T17:00:00Z',
      'end' => '2024-01-02T01:00:00Z',
      'tz_offset_minutes' => -420,
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    job_post = posts.find { |p| p[:posts][:references] == ['qbt:job:2'] }
    md = job_post[:posts][:attachments][0][:markdown]

    assert_includes md, '**Shift:** 10:00am to 6:00pm'
  end

  def test_timesheet_event_uses_end_time_for_timestamp
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'start' => '2024-01-01T17:00:00Z',
      'end' => '2024-01-01T18:00:00Z',
      'tz_offset_minutes' => -420,
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    job_post = posts.find { |p| p[:posts][:references] == ['qbt:job:2'] }
    _start_t, end_t = QuickbooksTime::Missive::PostBuilder.compute_times(ts)
    assert_equal end_t.utc.to_i, job_post[:posts][:attachments][0][:timestamp]
  end
end
