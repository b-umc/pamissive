require 'minitest/autorun'
require 'timeout'
require_relative '../lib/quickbooks_time/rate_limiter'
require_relative '../nonblock_socket/select_controller'

class RateLimiterTest < Minitest::Test
  def setup
    SelectController.instance.reset
  end

  def test_enforces_interval_without_blocking
    limiter = RateLimiter.new(interval: 0.1)
    times = []

    limiter.wait_until_allowed { times << Time.now }
    limiter.wait_until_allowed { times << Time.now }

    select_thread = Thread.new { SelectController.run }

    Timeout.timeout(5) do
      sleep 0.05 until times.size == 2
    end

    select_thread.kill

    assert times[1] - times[0] >= 0.1
  end
end
