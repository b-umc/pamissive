# frozen_string_literal: true

class QuickbooksTime
  module DB
    module Schema
      module_function

      def ensure!(conn, rebuild_timesheets: false)
        create_users(conn)
        create_jobs(conn)
        create_sync_logs(conn)

        if rebuild_timesheets
          rebuild_timesheets!(conn)
        else
          create_timesheets(conn)
          ensure_timesheet_meta_columns(conn)
          create_timesheet_index(conn)
        end
      end

      def create_users(conn)
        conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS quickbooks_time_users (
            id BIGINT PRIMARY KEY,
            first_name TEXT,
            last_name TEXT,
            username TEXT,
            email TEXT,
            active BOOLEAN,
            last_modified TIMESTAMPTZ,
            created TIMESTAMPTZ,
            raw JSONB
          );
        SQL
      end

      def create_jobs(conn)
        conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS quickbooks_time_jobs (
            id BIGINT PRIMARY KEY,
            parent_id BIGINT,
            name TEXT,
            short_code TEXT,
            type TEXT,
            billable BOOLEAN,
            billable_rate NUMERIC,
            has_children BOOLEAN,
            assigned_to_all BOOLEAN,
            required_customfields JSONB,
            filtered_customfielditems JSONB,
            active BOOLEAN,
            last_modified TIMESTAMPTZ,
            created TIMESTAMPTZ
          );
        SQL
      end

      def create_timesheets(conn)
        conn.exec(<<~SQL)
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
            entry_type TEXT,
            missive_post_id TEXT,
            start_time TIMESTAMPTZ,
            end_time TIMESTAMPTZ,
            tz_offset_minutes INTEGER,
            created_qbt TIMESTAMPTZ,
            modified_qbt TIMESTAMPTZ,
            created_at TIMESTAMPTZ DEFAULT now(),
            updated_at TIMESTAMPTZ DEFAULT now()
          );
        SQL
      end

      def rebuild_timesheets!(conn)
        conn.exec('DROP TABLE IF EXISTS quickbooks_time_timesheets;')
        create_timesheets(conn)
        create_timesheet_index(conn)
      end

      def create_sync_logs(conn)
        conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS api_sync_logs (
            id SERIAL PRIMARY KEY,
            api_name VARCHAR NOT NULL UNIQUE,
            last_successful_sync TIMESTAMPTZ,
            last_id BIGINT
          );
        SQL

        conn.exec(<<~SQL)
          ALTER TABLE api_sync_logs
            ADD COLUMN IF NOT EXISTS last_successful_sync TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS last_id BIGINT;
        SQL
      end

      def ensure_timesheet_meta_columns(conn)
        conn.exec(<<~SQL)
          ALTER TABLE quickbooks_time_timesheets
            ADD COLUMN IF NOT EXISTS entry_type TEXT,
            ADD COLUMN IF NOT EXISTS missive_post_id TEXT,
            ADD COLUMN IF NOT EXISTS start_time TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS end_time TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS tz_offset_minutes INTEGER,
            ADD COLUMN IF NOT EXISTS created_qbt TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS modified_qbt TIMESTAMPTZ;
        SQL
      end

      def create_timesheet_index(conn)
        conn.exec(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_qbt_job_unbilled
            ON quickbooks_time_timesheets (quickbooks_time_jobsite_id)
            WHERE billed = false;
        SQL
      end
    end
  end
end

