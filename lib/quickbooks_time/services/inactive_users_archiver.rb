# frozen_string_literal: true

require 'date'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

require_relative '../missive/client'

class InactiveUsersArchiver
  def initialize(repos, client: QuickbooksTime::Missive::Client.new)
    @repos = repos
    @client = client
  end

  # Archives (closes) Missive conversations for users marked inactive in QBT.
  # Adds optional shared label QBT_INACTIVE_USERS_LABEL_ID if present.
  # Set dry_run: true to only log intended actions.
  def run(dry_run: false, &done)
    rows = @repos.users.inactive_with_conversation rescue []
    LOG.debug [:inactive_users_to_archive, rows.size]

    label_inactive = ENV['QBT_INACTIVE_USERS_LABEL_ID']
    team = ENV.fetch('QBT_POST_TEAM', nil)
    org  = ENV.fetch('MISSIVE_ORG_ID', nil)

    idx = 0
    step = proc do
      if idx >= rows.length
        done&.call(true)
        next
      end
      r = rows[idx]
      idx += 1
      conv = r['missive_conversation_id']
      user_name = [r['first_name'], r['last_name']].compact.join(' ').strip
      user_name = "User #{r['id']}" if user_name.empty?

      if dry_run
        LOG.info [:would_archive_user_conversation, r['id'], conv]
        return step.call
      end

      payload = {
        conversation: conv,
        username: 'QuickBooks Time',
        notification: { title: "Archived • #{user_name}", body: 'User marked inactive in QuickBooks Time.' },
        attachments: [{ markdown: "_Archiving conversation for inactive user #{user_name} on #{Date.today}_.", timestamp: Time.now.to_i }],
        add_to_inbox: false,
        add_to_team_inbox: false,
        close: true,
        reopen: false,
        team: team,
        organization: org,
        add_shared_labels: (label_inactive ? [label_inactive] : nil)
      }.compact

      @client.create_post(payload) do |status, _hdrs, _body|
        if (200..299).include?(status)
          LOG.debug [:archived_user_conversation, r['id'], conv]
        else
          LOG.error [:archive_user_conversation_failed, r['id'], conv, :status, status]
        end
        step.call
      end
    end

    step.call
  rescue => e
    LOG.error [:inactive_users_archive_failed, e.class, e.message]
    done&.call(false)
  end
end

