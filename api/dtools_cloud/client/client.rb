# frozen_string_literal: true

require_relative 'parsing'
require_relative 'event'
require_relative 'pg'
require_relative 'details'

class DTools; end

module DTools::Client
  include Details
  include Event
  include Parsing
  include PG
end
