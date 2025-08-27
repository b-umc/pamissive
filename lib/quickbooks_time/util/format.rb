# frozen_string_literal: true

module Util
  module Format
    #def self.fmt_hm(seconds)
    #  h = seconds.to_i / 3600
    #  m = (seconds.to_i % 3600) / 60
    #  "#{h}h #{m}m"
    #end

    def self.notif_from_md(md, limit = 140)
      plain = md.gsub(/```.*?```/m, '')
                .gsub(/`([^`]*)`/, '\1')
                .gsub(/\*\*([^*]+)\*\*/, '\1')
                .gsub(/\*([^*]+)\*/, '\1')
                .gsub(/^>\s*/, '')
                .gsub(/\[(.*?)\]\((.*?)\)/, '\1')
                .gsub(/[_#]/, '')
                .strip
      plain.length > limit ? "#{plain[0, limit - 1]}…" : plain
    end
    
  end
end
