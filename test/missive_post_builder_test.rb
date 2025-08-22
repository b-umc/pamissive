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
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts, job_conversation_id: 'jobc', user_conversation_id: 'userc')
    job_post, tech_post = posts
    job_md = job_post[:posts][:attachments][0][:markdown]
    tech_md = tech_post[:posts][:attachments][0][:markdown]

    assert_equal ['qbt:job:2'], job_post[:posts][:references]
    assert_equal ['qbt:user:3'], tech_post[:posts][:references]
    assert_includes job_md, 'John Doe • Main Site'
    assert_includes job_md, '(missive://mail.missiveapp.com/#/conversations/userc)'
    assert_includes tech_md, '(missive://mail.missiveapp.com/#/conversations/jobc)'
  end

  def test_timesheet_event_includes_timezone
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'start' => '2024-01-01T17:00:00Z',
      'end' => '2024-01-02T01:00:00Z',
      'tz_offset_minutes' => 420,
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    md = posts.first[:posts][:attachments][0][:markdown]
    assert_includes md, 'Shift: 10:00am to 6:00pm'
  end

  def test_timesheet_event_uses_end_time_for_timestamp
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'start' => '2024-01-01T17:00:00Z',
      'end' => '2024-01-01T18:00:00Z',
      'tz_offset_minutes' => 420,
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    _start_t, end_t = QuickbooksTime::Missive::PostBuilder.compute_times(ts)
    assert_equal end_t.utc.to_i, posts.first[:posts][:attachments][0][:timestamp]
  end
end
