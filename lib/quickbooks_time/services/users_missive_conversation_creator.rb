# frozen_string_literal: true

require_relative '../missive/client'
require_relative '../util/format'
require_relative '../rate_limiter'
require_relative '../util/constants'

class UsersMissiveConversationCreator
  def initialize(users_repo)
    @users_repo = users_repo
    @missive_client = QuickbooksTime::Missive::Client.new
    @limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)
  end

  def run
    users_to_update = @users_repo.users_without_conversation
    users_to_update.each do |user|
      @limiter.wait_until_allowed do
        create_conversation_for_user(user)
      end
    end
  end

  private

  def create_conversation_for_user(user)
    user_id = user['id']
    user_name = "#{user['first_name']} #{user['last_name']}"
    markdown = "Timesheet entries for #{user_name}"
    payload = {
      posts: {
        references: ["qbt:user:#{user_id}"],
        conversation_subject: "QuickBooks Time: #{user_name}",
        notification: { title: "Timesheet • #{user_name}", body: ::Util::Format.notif_from_md(markdown) },
        attachments: [{ markdown: markdown }],
        organization: ENV.fetch('MISSIVE_ORG_ID', nil)
      }
    }
    @missive_client.post(payload) do |response|
      if response && (200..299).include?(response.code)
        begin
          body = JSON.parse(response.body)
          conversation = body.dig('posts', 'conversation')
          conversation_id = conversation.is_a?(Hash) ? conversation['id'] : conversation
          if conversation_id
            @users_repo.update_conversation_id(user_id, conversation_id)
          end
        rescue JSON::ParserError
          # ignore
        end
      end
    end
  end
end
