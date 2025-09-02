ALTER TABLE quickbooks_time_timesheets
  ADD COLUMN IF NOT EXISTS on_the_clock boolean DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_qbt_timesheets_on_the_clock
  ON quickbooks_time_timesheets (on_the_clock)
  WHERE on_the_clock IS TRUE;
