# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/quickbooks_time/streams/jobs_stream'

class JobsStreamPaginationTest < Minitest::Test
  FakeClient = Struct.new(:responses) do
    def jobcodes(page:, limit:, &blk)
      blk.call(responses.shift)
    end
  end

  def test_continues_through_empty_pages
    responses = [
      { 'results' => { 'jobcodes' => { '1' => { 'id' => 1 } } }, 'more' => true },
      { 'results' => { 'jobcodes' => {} }, 'more' => true },
      { 'results' => { 'jobcodes' => { '2' => { 'id' => 2 } } }, 'more' => false }
    ]
    client = FakeClient.new(responses)
    rows = []
    done_called = false

    JobsStream.new(qbt_client: client, limit: 1).each_batch(->(batch) { rows.concat(batch) }) do |ok|
      done_called = true
      assert ok
    end

    assert_equal [{ 'id' => 1 }, { 'id' => 2 }], rows
    assert done_called
  end
end
