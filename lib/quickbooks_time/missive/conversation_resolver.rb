# frozen_string_literal: true

require 'json'
require_relative '../../../api/missive/missive'

class QuickbooksTime
  module Missive
    module ConversationResolver
      module_function

      def ensure_job(job_id, repo)
        ensure_id(repo, job_id, "qbt:job:#{job_id}")
      end

      def ensure_user(user_id, repo)
        ensure_id(repo, user_id, "qbt:user:#{user_id}")
      end

      def ensure_id(repo, key, reference)
        convo_id = repo.conversation_id(key)
        return convo_id if convo_id && !convo_id.empty?

        convo_id = search(reference)
        convo_id ||= create_placeholder(reference)
        repo.set_conversation_id(key, convo_id) if convo_id
        convo_id
      end

      def search(reference)
        result = nil
        MISSIVE.channel_get("conversations?references=#{reference}") do |resp|
          body = JSON.parse(resp.body) rescue {}
          result = body['conversations']&.first&.dig('id')
        end
        result
      end

      def create_placeholder(reference)
        convo_id = nil
        post_id = nil
        MISSIVE.channel_post('posts', {
          posts: {
            references: [reference],
            username: 'QuickBooks Time',
            attachments: [{ markdown: 'Initializing conversation' }],
            add_to_inbox: false,
            add_to_team_inbox: false
          }
        }) do |resp|
          ids = MISSIVE.parse_ids(resp)
          convo_id = ids[:conversation_id]
          post_id = ids[:post_id]
        end
        MISSIVE.delete_post(post_id) if post_id
        convo_id
      end
    end
  end
end
