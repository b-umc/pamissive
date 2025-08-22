# frozen_string_literal: true

class QuickbooksTime
  module PGCreate
    CREATE_TABLES = {
      'quickbooks_time_overview_state' => %{
        CREATE TABLE IF NOT EXISTS quickbooks_time_overview_state (
          quickbooks_time_jobsite_id BIGINT PRIMARY KEY,
          missive_conversation_id TEXT,
          overview_post_id TEXT,
          status TEXT NOT NULL DEFAULT 'unbilled',
          invoice_id TEXT,
          invoice_url TEXT,
          total_unbilled_seconds INTEGER NOT NULL DEFAULT 0,
          updated_at TIMESTAMPTZ DEFAULT now()
        );
      },
      'quickbooks_time_timesheets' => %{
        CREATE TABLE IF NOT EXISTS quickbooks_time_timesheets (
          id BIGINT PRIMARY KEY,
          quickbooks_time_jobsite_id BIGINT NOT NULL,
          user_id BIGINT NOT NULL,
          date DATE NOT NULL,
          duration_seconds INTEGER NOT NULL,
          notes TEXT,
          last_hash TEXT,
          billed BOOLEAN NOT NULL DEFAULT false,
          billed_invoice_id TEXT,
          created_at TIMESTAMPTZ DEFAULT now(),
          updated_at TIMESTAMPTZ DEFAULT now()
        );
      },
      'idx_qbt_job_unbilled' => %{
        CREATE INDEX IF NOT EXISTS idx_qbt_job_unbilled
        ON quickbooks_time_timesheets (quickbooks_time_jobsite_id)
        WHERE billed = false;
      },
      'quickbooks_time_jobsite_conversations' => %{
        CREATE TABLE IF NOT EXISTS quickbooks_time_jobsite_conversations (
          id SERIAL PRIMARY KEY,
          quickbooks_time_jobsite_id BIGINT NOT NULL UNIQUE,
          missive_conversation_id VARCHAR(255) NOT NULL,
          created_at TIMESTAMPTZ DEFAULT now()
        );
      },
      'quickbooks_time_backfill_status' => %{
        CREATE TABLE IF NOT EXISTS quickbooks_time_backfill_status (
          id SERIAL PRIMARY KEY,
          quickbooks_time_jobsite_id BIGINT NOT NULL UNIQUE,
          last_successful_sync TIMESTAMPTZ
        );
      },
      'quickbooks_time_users' => %{
        CREATE TABLE IF NOT EXISTS quickbooks_time_users (
          id BIGINT PRIMARY KEY,
          first_name TEXT,
          last_name TEXT,
          username TEXT,
          email TEXT,
          active BOOLEAN,
          last_modified TIMESTAMPTZ,
          created TIMESTAMPTZ,
          missive_conversation_id TEXT,
          raw JSONB
        );
      }
    }.freeze

    MIGRATIONS = {
      'add_missive_conversation_ids' => %{
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_jobs' AND column_name='missive_conversation_id'
          ) THEN
            ALTER TABLE quickbooks_time_jobs ADD COLUMN missive_conversation_id TEXT;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_users' AND column_name='missive_conversation_id'
          ) THEN
            ALTER TABLE quickbooks_time_users ADD COLUMN missive_conversation_id TEXT;
          END IF;

          IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_name='quickbooks_time_jobsite_conversations'
          ) THEN
            UPDATE quickbooks_time_jobs j
            SET missive_conversation_id = c.missive_conversation_id
            FROM quickbooks_time_jobsite_conversations c
            WHERE j.id = c.quickbooks_time_jobsite_id
              AND j.missive_conversation_id IS NULL;
          END IF;
        END $$;
      },
      'ensure_timesheet_meta_columns' => %{
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_timesheets' AND column_name='entry_type'
          ) THEN
            ALTER TABLE quickbooks_time_timesheets ADD COLUMN entry_type TEXT;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_timesheets' AND column_name='start_time'
          ) THEN
            ALTER TABLE quickbooks_time_timesheets ADD COLUMN start_time TIMESTAMPTZ;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_timesheets' AND column_name='end_time'
          ) THEN
            ALTER TABLE quickbooks_time_timesheets ADD COLUMN end_time TIMESTAMPTZ;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_timesheets' AND column_name='created_qbt'
          ) THEN
            ALTER TABLE quickbooks_time_timesheets ADD COLUMN created_qbt TIMESTAMPTZ;
          END IF;

          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_timesheets' AND column_name='modified_qbt'
          ) THEN
            ALTER TABLE quickbooks_time_timesheets ADD COLUMN modified_qbt TIMESTAMPTZ;
          END IF;
        END $$;
      },

      'drop_overview_conversation_id' => %{
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_overview_state' AND column_name='missive_conversation_id'
          ) THEN
            ALTER TABLE quickbooks_time_overview_state DROP COLUMN missive_conversation_id;
          END IF;
        END $$;
      },

      'fix_conversations_jobsite_id_bigint' => %{
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name='quickbooks_time_jobsite_conversations'
              AND column_name='quickbooks_time_jobsite_id'
              AND data_type='integer'
          ) THEN
            ALTER TABLE quickbooks_time_jobsite_conversations
              ALTER COLUMN quickbooks_time_jobsite_id TYPE BIGINT;
          END IF;
        END $$;
      }
    }.freeze
  end
end
