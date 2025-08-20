# frozen_string_literal: true

require_relative '../../nonblock_socket/select_controller'

class RateLimiter
  include TimeoutInterface

  def initialize(interval:, tokens: 1)
    @interval = interval
    @tokens = tokens
    @next_time = Time.at(0)
  end

  def wait_until_allowed(&blk)
    return unless blk

    now    = Time.now
    run_at = [now, @next_time].max
    @next_time = run_at + @interval
    delay  = run_at - now

    if delay.positive?
      add_timeout(proc { blk.call }, delay)
    else
      blk.call
    end
  end
end
