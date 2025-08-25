# frozen_string_literal: true

require_relative '../missive/client'
require_relative '../missive/task_builder'
require_relative '../rate_limiter'
require_relative '../util/constants'

class TimesheetsForMissiveCreator
  def initialize(repos)
    @repos = repos
    @missive_client = QuickbooksTime::Missive::Client.new
    @limiter = RateLimiter.new(interval: Constants::MISSIVE_POST_MIN_INTERVAL)
  end

  def run(&callback)
    # This query now finds all timesheets that either need tasks created OR need their state updated.
    timesheets_to_process = @repos.timesheets.tasks_to_create_or_update(Date.today << Constants::MISSIVE_BACKFILL_MONTHS)
    
    process_next_timesheet = proc do
      if timesheets_to_process.empty?
        callback&.call
      else
        ts = timesheets_to_process.shift
        # The limiter is now only at the top level, ensuring we process one timesheet at a time.
        # The chaining inside process_one_timesheet will handle the rest.
        process_one_timesheet(ts, &process_next_timesheet)
      end
    end

    process_next_timesheet.call
  end

  private

  def process_one_timesheet(ts, &callback)
    # This is the main sequential flow for a single timesheet.
    # Each step calls the next one in its completion block,
    # with rate limiters between each API call.
    @limiter.wait_until_allowed do
      create_jobsite_task_if_needed(ts) do
        @limiter.wait_until_allowed do
          create_user_task_if_needed(ts) do
            @limiter.wait_until_allowed do
              update_task_states_if_needed(ts, &callback)
            end
          end
        end
      end
    end
  end

  def create_jobsite_task_if_needed(ts, &callback)
    return callback.call if ts['missive_jobsite_task_id']
    
    payload = QuickbooksTime::Missive::TaskBuilder.build_jobsite_task_creation_payload(ts)
    @missive_client.create_task(payload) do |response|
      if response && (200..299).include?(response.code)
        body = JSON.parse(response.body) rescue {}
        task_id = body.dig('tasks', 'id')
        convo_id = body.dig('tasks', 'links_to_conversation', 0, 'id')
        ts['missive_jobsite_task_id'] = task_id # Update in memory for the next step
        @repos.timesheets.save_task_id(ts['id'], task_id, :jobsite, conversation_id: convo_id) if task_id
      end
      callback.call
    end
  end

  def create_user_task_if_needed(ts, &callback)
    return callback.call if ts['missive_user_task_id']

    payload = QuickbooksTime::Missive::TaskBuilder.build_user_task_creation_payload(ts)
    @missive_client.create_task(payload) do |response|
      if response && (200..299).include?(response.code)
        body = JSON.parse(response.body) rescue {}
        task_id = body.dig('tasks', 'id')
        convo_id = body.dig('tasks', 'links_to_conversation', 0, 'id')
        ts['missive_user_task_id'] = task_id # Update in memory for the next step
        @repos.timesheets.save_task_id(ts['id'], task_id, :user, conversation_id: convo_id) if task_id
      end
      callback.call
    end
  end

  def update_task_states_if_needed(ts, &callback)
    desired_state = QuickbooksTime::Missive::TaskBuilder.determine_task_state(ts)
    
    return callback.call if ts['missive_task_state'] == desired_state

    update_payload = QuickbooksTime::Missive::TaskBuilder.build_task_update_payload(ts)

    update_single_task(ts['missive_jobsite_task_id'], update_payload) do
      @limiter.wait_until_allowed do
        update_single_task(ts['missive_user_task_id'], update_payload) do
          @repos.timesheets.update_task_state(ts['id'], desired_state)
          callback.call
        end
      end
    end
  end

  def update_single_task(task_id, payload, &callback)
    return callback.call unless task_id

    @missive_client.update_task(task_id, payload) do |response|
      unless response && (200..299).include?(response.code)
        LOG.error [:missive_task_update_failed, task_id, response&.code]
      end
      callback.call
    end
  end
end
