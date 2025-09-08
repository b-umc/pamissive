# frozen_string_literal: true

require 'date'
require_relative '../../../logging/app_logger'
LOG = AppLogger.setup(__FILE__, log_level: Logger::DEBUG) unless defined?(LOG)

class QuickbooksTime
  module Missive
    # Coalesced queue for per-conversation daily summaries.
    #
    # Keyed by [conversation_id, type, date] where type is :user or :job.
    class SummaryQueue
      # @pending maps [conversation_id, type, date] => Time enqueued_at
      @pending = {}
      # Post IDs persisted via repo; memory cache no longer needed
      @draining = false
      @last_verify_at = nil

      class << self
        # Enqueue a conversation/day to summarize.
        # @param conversation_id [String]
        # @param type [Symbol] :user or :job
        # @param date [String, Date]
        def enqueue(conversation_id:, type:, date:)
          return unless conversation_id && type && date
          d = date.is_a?(Date) ? date : (Date.parse(date.to_s) rescue nil)
          return unless d
          # Only post summaries for today by default; allow historical when enabled.
          allow_hist = ENV.fetch('MISSIVE_SUMMARY_ALLOW_HISTORICAL', '0') == '1'
          if d != Date.today && !allow_hist
            LOG.debug [:summary_enqueue_skipped_non_today, conversation_id.to_s, type.to_sym, d.to_s]
            return
          end
          key = [conversation_id.to_s, type.to_sym, d.to_s]
          @pending[key] = Time.now
          LOG.debug [:summary_enqueue, *key, :at, @pending[key].iso8601]
        rescue => e
          LOG.error [:summary_enqueue_error, e.class, e.message]
        end

        # Mark that a verification cycle has completed. Summaries will only be
        # posted for keys enqueued at or before this checkpoint to ensure we
        # have reconciled task state first.
        def verify_completed!
          @last_verify_at = Time.now
          LOG.debug [:summary_verify_checkpoint, @last_verify_at.iso8601]
        end

        # Drain pending summaries after tasks have been processed.
        # Calls the optional block when done.
        def drain(client:, repo: nil, &done)
          return done&.call unless repo
          return done&.call if @draining
          # Require a verification checkpoint before posting summaries
          unless @last_verify_at
            LOG.debug [:summary_drain_skipped_no_verify]
            return done&.call
          end

          # Select only keys for today that were enqueued before or at the
          # last verification checkpoint.
          allow_hist = ENV.fetch('MISSIVE_SUMMARY_ALLOW_HISTORICAL', '0') == '1'
          today_s = Date.today.to_s
          keys = @pending.select { |k, t| (allow_hist || k[2] == today_s) && t <= @last_verify_at }.keys
          # Remove only the keys we plan to process; keep later ones pending
          keys.each { |k| @pending.delete(k) }
          return done&.call if keys.empty?

          @draining = true

          process = proc do
            key = keys.shift
            unless key
              @draining = false
              done&.call
              next
            end
            conversation_id, type, date_s = key

            delete_previous_and_post(client: client, repo: repo, key: key, &process)
          end

          process.call
        end

        private

        def delete_previous_and_post(client:, repo:, key:, &next_step)
          conversation_id, type, date_s = key
          begin
            prev_id = repo.get_summary_post_id(conversation_id: conversation_id, type: type, date: date_s)
          rescue => e
            LOG.error [:summary_prev_lookup_error, e.class, e.message]
            prev_id = nil
          end
          if prev_id
            client.delete_post(prev_id) do |status, _hdrs, _body|
              begin
                if (200..299).include?(status)
                  repo.clear_summary_post_id(conversation_id: conversation_id, type: type, date: date_s)
                end
              rescue => e
                LOG.warn [:summary_prev_clear_error, e.class, e.message]
              ensure
                build_and_post_summary(client: client, repo: repo, key: key, &next_step)
              end
            end
          else
            build_and_post_summary(client: client, repo: repo, key: key, &next_step)
          end
        end

        def build_and_post_summary(client:, repo:, key:, &next_step)
          conversation_id, type, date_s = key
          summary = repo.daily_summary_for_conversation(conversation_id: conversation_id, type: type, date: date_s)
          md = markdown_for(summary: summary, type: type, date: date_s)
          if md.nil?
            # No content to post; advance
            next_step.call
            return
          end

          # Build payload
          team = ENV.fetch('QBT_POST_TEAM', nil)
          org  = ENV.fetch('MISSIVE_ORG_ID', nil)

          # Labels: always add QBT_LABEL_ID; add Users/Jobsites based on type
          qbt_label      = ENV['QBT_LABEL_ID']
          jobsites_label = ENV['QBT_JOBSITES_LABEL_ID']
          users_label    = ENV['QBT_USERS_LABEL_ID']
          add_labels = [qbt_label]
          add_labels << (type.to_sym == :job ? jobsites_label : users_label)
          add_labels.compact!

          payload = {
            conversation: conversation_id,
            username: 'Daily Summary',
            notification: notify_for(md, date_s),
            attachments: [{ markdown: md, timestamp: Time.now.to_i }],
            add_to_inbox: false,
            add_to_team_inbox: false,
            team: team,
            organization: org,
            add_shared_labels: (add_labels if add_labels && !add_labels.empty?)
          }.compact

          client.create_post(payload) do |status, _hdrs, body|
            if (200..299).include?(status)
              post_id = body&.dig('posts', 'id')
              if post_id
                begin
                  repo.save_summary_post_id(
                    conversation_id: conversation_id,
                    type: type,
                    date: date_s,
                    post_id: post_id
                  )
                rescue => e
                  LOG.error [:summary_post_id_save_error, e.class, e.message]
                end
              end
              LOG.debug [:summary_posted, conversation_id, type, date_s, :post_id, post_id]
            else
              LOG.error [:summary_post_failed, conversation_id, type, date_s, :status, status]
            end
            next_step.call
          end
        rescue => e
          LOG.error [:summary_build_post_error, e.class, e.message]
          next_step.call
        end

        def notify_for(md, date_s)
          title = "Daily Hours • #{date_s}"
          body  = md.to_s.gsub(/[*_`>#]/, '').gsub(/\s+/, ' ').strip[0, 240]
          { title: title, body: body }
        end

        def markdown_for(summary:, type:, date:)
          return nil unless summary && summary[:items] && summary[:items].any?
          lines = []
          header = (type.to_sym == :job) ? "Job Daily Hours" : "User Daily Hours"
          lines << "**#{header} — #{date}**"
          summary[:items].each do |it|
            hours = (it[:seconds].to_i / 3600.0)
            lines << "- #{it[:label]}: #{format('%.2f', hours)}h"
          end
          total_h = (summary[:total_seconds].to_i / 3600.0)
          lines << "**Total: #{format('%.2f', total_h)}h**"
          lines.join("\n")
        end
      end
    end
  end
end
