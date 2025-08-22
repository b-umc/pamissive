# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/quickbooks_time/missive/post_builder'

class MissivePostBuilderTest < Minitest::Test
  def test_timesheet_event_builds_cross_linked_posts
    ts = {
      'id' => 1,
      'quickbooks_time_jobsite_id' => 2,
      'user_id' => 3,
      'user_name' => 'Jane Doe',
      'jobsite_name' => 'Site A',
      'duration' => 3600,
      'date' => '2024-01-01'
    }
    posts = QuickbooksTime::Missive::PostBuilder.timesheet_event(ts)

    assert_equal 2, posts.length
    job_post, tech_post = posts

    assert_equal ['qbt:job:2'], job_post[:posts][:references]
    assert_match(/Jane Doe/, job_post[:posts][:attachments][0][:markdown])
    assert_includes job_post[:posts][:attachments][0][:markdown], '(ref:qbt:user:3,qbt:job:2)'

    assert_equal ['qbt:user:3', 'qbt:job:2'], tech_post[:posts][:references]
    assert_match(/Site A/, tech_post[:posts][:attachments][0][:markdown])
    assert_includes tech_post[:posts][:attachments][0][:markdown], '(ref:qbt:job:2)'
  end
end
