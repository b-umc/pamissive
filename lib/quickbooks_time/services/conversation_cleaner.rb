# frozen_string_literal: true

class ConversationCleaner
  def initialize(repos)
    @users_repo = repos.users
    @jobs_repo = repos.jobs
    @db = repos.users.instance_variable_get(:@db) # A way to get the db connection
  end

  def run(&callback)
    @db.exec('UPDATE quickbooks_time_users SET missive_conversation_id = NULL') do
      @db.exec('UPDATE quickbooks_time_jobs SET missive_conversation_id = NULL') do
        callback&.call
      end
    end
  end
end
