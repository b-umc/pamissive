# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/quickbooks_time/missive/post_builder'

class MissivePostBuilderTest < Minitest::Test
  def test_timesheet_event_builds_post
    ts = {
      'id' => 1,
      'jobcode_id' => 2,
      'user_id' => 3,
      'duration' => 3600,
      'date' => '2024-01-01',
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    post = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)

    assert_equal ['qbt:job:2'], post[:posts][:references]
    assert_equal 'QuickBooks Time', post[:posts][:username]
    assert_match(/John Doe/, post[:posts][:attachments][0][:markdown])
    assert_match(/Main Site/, post[:posts][:attachments][0][:markdown])
    assert_equal Constants::STATUS_COLORS['unknown'], post[:posts][:attachments][0][:color]
    assert_match(/John Doe/, post[:posts][:notification][:title])
    assert_match(/Main Site/, post[:posts][:conversation_subject])
  end

  def test_timesheet_event_includes_timezone
    ts = {
      'id' => 1,
      'jobcode_id' => 2,
      'user_id' => 3,
      'start' => '2024-01-01T10:00:00-07:00',
      'end' => '2024-01-01T18:00:00-07:00',
      'user_name' => 'John Doe',
      'jobsite_name' => 'Main Site'
    }
    post = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)
    md = post[:posts][:attachments][0][:markdown]

    assert_includes md, 'Start: 2024-01-01 10:00 -07:00'
    assert_includes md, 'End: 2024-01-01 18:00 -07:00'
  end
end
