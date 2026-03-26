-- Migration: Add trial_available column to requests table
-- This tracks whether a free trial account is available for a candidate service.
-- Values:
--   'yes'               - Free trial / developer tier / freemium plan available
--   'no'                - No free trial detected
--   'account_available' - Team already has an account (Azure, AWS, GCP)
--   'unknown'           - Not yet evaluated (default for existing rows)

ALTER TABLE public.requests
    ADD COLUMN IF NOT EXISTS trial_available TEXT DEFAULT 'unknown';

-- Add CHECK constraint separately (IF NOT EXISTS not supported for constraints in all PG versions)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'requests_trial_available_check'
    ) THEN
        ALTER TABLE public.requests
            ADD CONSTRAINT requests_trial_available_check
            CHECK (trial_available IN ('yes', 'no', 'account_available', 'unknown'));
    END IF;
END$$;
