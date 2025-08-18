# frozen_string_literal: true

class RateLimiter
  def initialize(interval:, tokens: 1)
    @interval = interval
    @tokens = tokens
    @last_time = Time.at(0)
  end

  def wait_until_allowed
    now = Time.now
    wait = (@last_time + @interval) - now
    sleep(wait) if wait.positive?
    @last_time = Time.now
    yield if block_given?
  end
end
