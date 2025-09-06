# frozen_string_literal: true

require 'time'
require_relative '../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

module Shared
  module DT
    class << self
      # Parse any time string into UTC Time (best-effort).
      # Logs conversion if DT_DEBUG_LOGGING=1 to trace precision.
      def parse_utc(str, source: nil)
        return nil if str.nil? || str == ''
        t = nil
        begin
          if Time.respond_to?(:iso8601)
            t = Time.iso8601(str)
          else
            t = Time.parse(str)
          end
        rescue ArgumentError, TypeError
          begin
            s2 = (str.include?(' ') && str =~ /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:/) ? str.tr(' ', 'T') : str
            t = Time.respond_to?(:iso8601) ? Time.iso8601(s2) : Time.parse(s2)
          rescue StandardError => e
            begin
              t = Time.parse(str)
            rescue StandardError => e2
              LOG.warn [:dt_parse_failed, source, str, e2.class, e2.message] if ENV.fetch('DT_LOG_PARSE_FAILURES', '0') == '1'
              return nil
            end
          end
        rescue NoMethodError => e
          begin
            t = Time.parse(str)
          rescue StandardError => e3
            LOG.warn [:dt_parse_failed, source, str, e3.class, e3.message] if ENV.fetch('DT_LOG_PARSE_FAILURES', '0') == '1'
            return nil
          end
        end

        t = t.getutc
        if ENV.fetch('DT_DEBUG_LOGGING', '0') == '1'
          LOG.debug [source || :dt_input_time, str, :to, :internal_time, t.iso8601]
        end
        t
      end

      # Convert to ISO8601 UTC string
      def iso8601_utc(time)
        return nil unless time
        (time.is_a?(Time) ? time.getutc : parse_utc(time))&.iso8601
      end
    end
  end
end
