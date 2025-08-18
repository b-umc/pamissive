require 'logger'
require 'fileutils'

class AppLogger
  def self.setup(file_name = nil, log_path: STDOUT, log_level: Logger::WARN)
    script_name = File.basename(file_name, '.*')
    if file_name == STDOUT
      logger = Logger.new(STDOUT)
    else 
      log_path == STDOUT

      log_path = "#{log_path}/#{script_name}/"
      FileUtils.mkdir_p(log_path)

      log_filename = "#{log_path}#{script_name}_#{Time.now.strftime('%Y-%m-%d')}.log"

      logger = Logger.new(log_filename, 10, 1024 * 1024 * 10)
    end

    logger.level = log_level

    # Extend logger to include a method for logging with caller details
    def logger.log_error(message)
      error_location = caller(1..1).first # gets the immediate caller's details
      error_message = "[#{error_location}] #{message}"
      error(error_message)
    end

    logger
  end
end
