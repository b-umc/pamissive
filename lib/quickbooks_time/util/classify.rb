# frozen_string_literal: true

module Util
  module Classify
    def self.classify_entry(ts)
      t = (ts['type'] || ts['Type'] || '').to_s.downcase
      return :manual  if t == 'manual'
      return :regular if t == 'regular'

      has_start = ts['start'].to_s.strip != ''
      has_end   = ts['end'].to_s.strip   != ''
      has_start || has_end ? :regular : :manual
    rescue StandardError
      :regular
    end
  end
end
