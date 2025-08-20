# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../nonblock_socket/select_controller'

class SelectControllerTimeoutTest < Minitest::Test
  def setup
    SelectController.instance.reset
    @orig_timeout = SelectController.send(:remove_const, :CALL_TIMEOUT)
    SelectController.const_set(:CALL_TIMEOUT, 0.05)
  end

  def teardown
    SelectController.send(:remove_const, :CALL_TIMEOUT)
    SelectController.const_set(:CALL_TIMEOUT, @orig_timeout)
    SelectController.instance.reset
  end

  def test_blocking_readable_callback_raises_timeout_error
    reader, writer = IO.pipe
    blocking = proc { sleep 0.1 }

    SelectController.instance.add_sock(blocking, reader)
    writer.write('hi')

    assert_raises(Timeout::Error) do
      SelectController.instance.send(:select_socks)
    end
  ensure
    reader.close
    writer.close
  end
end
