require 'minitest/autorun'
require 'logger'
require_relative '../lib/quickbooks_time/qbt_client'

class QbtClientApiErrorTest < Minitest::Test
  StubResponse = Struct.new(:code, :body)
  
  class StubSession
    def initialize(response)
      @response = response
    end
    def get(_url, _opts, log_debug: false)
      yield @response
    end
  end

  def test_api_request_logs_body_for_error
    token_provider = -> { 'token' }
    client = QbtClient.new(token_provider)
    response = StubResponse.new(417, '{"error":"fail"}')
    messages = []

    LOG.stub :error, ->(msg) { messages << msg } do
      NonBlockHTTP::Client::ClientSession.stub :new, StubSession.new(response) do
        client.send(:api_request, 'timesheets?foo=bar') { |resp| assert_nil resp }
      end
    end

    assert_includes messages.last, '{"error":"fail"}'
  end

  class CaptureSession
    attr_reader :url
    def get(url, _opts, log_debug: false)
      @url = url
      yield StubResponse.new(200, '{"results": {"timesheets": {}}, "more": false}')
    end
  end

  def test_timesheets_uses_supported_params
    token_provider = -> { 'token' }
    client = QbtClient.new(token_provider)
    session = CaptureSession.new

    NonBlockHTTP::Client::ClientSession.stub :new, session do
      client.timesheets_modified_since('1970-01-01T00:00:00Z', page: 2, limit: 100, supplemental: true) { |_| }
    end

    assert_match %r{timesheets\?}, session.url
    assert_includes session.url, 'start_date=1970-01-01'
    assert_includes session.url, 'modified_since=1970-01-01T00%3A00%3A00Z'
    assert_includes session.url, 'page=2'
    assert_includes session.url, 'limit=100'
    assert_includes session.url, 'supplemental_data=yes'
    refute_includes session.url, 'after_id'
    refute_includes session.url, 'sort_order'
  end
end
