# frozen_string_literal: true
$stdout.sync = true
$stderr.sync = true

Signal.trap('TERM') { warn 'TERM received'; exit 0 }
Signal.trap('INT')  { warn 'INT received';  exit 0 }

at_exit do
  e = $!
  warn "exiting: #{e.class}: #{e.message}" if e
end

require_relative '../logging/app_logger'
LOG = AppLogger.setup(STDOUT,log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../nonblock_socket/select_controller'

# def LOG.debug(*dat)
#   super(dat, caller)
# end

class LibLoader
  include TimeoutInterface
  def initialize(lib_array, &block)
    @complete = block
    sever_slow_load(lib_array)
  end

  def sever_slow_load(lib_array)
    lib = lib_array.shift
    LOG.debug([:loading, lib])
    require_relative lib
    return @complete.call if lib_array.empty?

    add_timeout(proc { sever_slow_load(lib_array) }, 1)
  end
end

LibLoader.new(
  %w[
    ../nonblock_HTTP/server/websocket_session
    ../env/token_manager
    ../nonblock_HTTP/manager
    auth_server
    session/session
  ]
) { JOBSITES = NonBlockHTML::Server::AuthServer.new(callback: method(:authorized)) unless defined?(JOBSITES) }

def authorized(session)
  @sessions ||= []
  @sessions << NonBlockHTML::Server::Session.new(session)
end

SelectController.run
