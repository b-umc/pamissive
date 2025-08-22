# frozen_string_literal: true

class QuickbooksTime
  module Missive
    module Conversation
      module_function

      def url(id, deep: false)
        scheme = deep ? 'missive' : 'https'
        "#{scheme}://mail.missiveapp.com/#/conversations/#{id}"
      end
    end
  end
end
