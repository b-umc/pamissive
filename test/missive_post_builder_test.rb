# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/quickbooks_time/missive/post_builder'

class MissivePostBuilderTest < Minitest::Test
  def test_timesheet_event_builds_post
    ts = { 'id' => 1, 'jobcode_id' => 2, 'user_id' => 3 }
    post = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)

    assert_equal ['qbt:job:2'], post[:posts][:references]
    assert_equal 'QuickBooks Time', post[:posts][:username]
    assert_equal 'Timesheet 1', post[:posts][:attachments][0][:markdown]
    assert_equal Constants::STATUS_COLORS['unknown'], post[:posts][:attachments][0][:color]
    assert_equal 'Timesheet 1', post[:posts][:notification][:body]
  end
end
