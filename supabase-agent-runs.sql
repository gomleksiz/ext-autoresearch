-- ============================================================
-- Agent Runs Table — tracks agent execution history
-- Run this in: Supabase Dashboard > SQL Editor
-- ============================================================

CREATE TABLE public.agent_runs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name      TEXT NOT NULL DEFAULT 'discovery-agent',
    status          TEXT NOT NULL DEFAULT 'success'
        CHECK (status IN ('success', 'partial', 'failed')),
    run_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    candidates_evaluated  INT DEFAULT 0,
    new_submitted         INT DEFAULT 0,
    duplicates_skipped    INT DEFAULT 0,
    below_threshold       INT DEFAULT 0,
    searches_performed    INT DEFAULT 0,
    errors          TEXT[] DEFAULT '{}',
    summary         JSONB,
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_agent_runs_run_at ON public.agent_runs(run_at DESC);
CREATE INDEX idx_agent_runs_agent ON public.agent_runs(agent_name);

ALTER TABLE public.agent_runs ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read runs
CREATE POLICY "Authenticated users can view runs"
    ON public.agent_runs FOR SELECT
    TO authenticated
    USING (true);

-- Authenticated users can insert runs (agent uses auth)
CREATE POLICY "Authenticated users can insert runs"
    ON public.agent_runs FOR INSERT
    TO authenticated
    WITH CHECK (true);

-- Enable realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_runs;
