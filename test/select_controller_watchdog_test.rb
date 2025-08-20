require 'minitest/autorun'
require_relative '../nonblock_socket/select_controller'

class SelectControllerWatchdogTest < Minitest::Test
  def setup
    @controller = SelectController.instance
    @controller.instance_variable_get(:@watchdog)&.kill
    @controller.instance_variable_set(:@select_thread, Thread.current)
    @controller.instance_variable_set(:@last_activity, Time.now)
    @controller.send(:start_watchdog)
  end

  def teardown
    @controller.instance_variable_get(:@watchdog)&.kill
  end

  def test_watchdog_logs_when_loop_stalls
    messages = []
    original_log = Object.const_get(:LOG)
    fake_log = Object.new
    fake_log.define_singleton_method(:error) { |msg| messages << msg }
    Object.send(:remove_const, :LOG)
    Object.const_set(:LOG, fake_log)

    @controller.instance_variable_set(:@last_activity, Time.now - (SelectController::STALL_TIMEOUT * 2))
    sleep SelectController::STALL_TIMEOUT * 2

    assert messages.any? { |msg| msg[0] == :select_blocked }
  ensure
    Object.send(:remove_const, :LOG)
    Object.const_set(:LOG, original_log)
  end
end
