---
name: m-implement-better-logs
branch: feature/better-logs
status: pending
created: 2026-03-23
---

# Add Better Logging

## Problem/Goal
The web interface shows Agent run history, but successful runs lack detail — only errors are visible. When a run succeeds, there's no indication of what actually happened. We need to add notes/logs to successful Agent runs so users can see what was accomplished.

## Success Criteria
- [ ] Successful Agent runs display notes/summary of what happened during the run
- [ ] Notes are visible in the run history view in the web interface
- [ ] Error runs continue to show error details as before (no regression)

## Context Manifest
<!-- Added by context-gathering agent -->

### Project Architecture Overview

This is a single-page web application (`index.html`) backed by Supabase (PostgreSQL + Auth + Realtime). It serves as an "Extension Requirements Tracker" for Stonebranch UAC Universal Extensions. The frontend is a monolithic HTML file (~2166 lines) containing all CSS, HTML, and JavaScript inline -- there are no build tools, no framework, no separate JS files. It is hosted on GitHub Pages.

Several Python agents run on cron schedules from the developer's machine. These agents authenticate against Supabase, do work (web research, requirements generation, analysis), and log their runs to the `agent_runs` table. The web UI subscribes to Supabase Realtime and renders the run history.

### How Agent Run History Currently Works: The Complete Flow

**Data Storage -- The `agent_runs` Table (Supabase)**

The table is defined in `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/supabase-agent-runs.sql`. Its schema is:

```sql
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
```

Key observations: The `summary` column is JSONB and can hold arbitrary structured data. The `errors` column is a TEXT array. There is no dedicated `notes` or `log_message` column -- any human-readable notes about what happened during a run currently only live inside the `summary` JSONB if agents choose to put them there. The `status` field has a CHECK constraint limiting it to 'success', 'partial', or 'failed'.

**Four Agent Types Log Runs**

1. **Discovery Agent** (`agents/runner.py`, `agent_name: 'discovery-agent'`): Logs `summary` as `{ competitor_research: {...}, below_threshold: [...], duplicates: [...] }`. Numeric metrics go into the dedicated columns. On success, the summary contains structured data about competitor gaps and skipped duplicates but no human-readable notes/narrative.

2. **Requirements Agent** (`agents/requirements_runner.py`, `agent_name: 'requirements-agent'`): Logs `summary` as `{ succeeded: [{title, path}], failed: [{title, error}] }`. The `candidates_evaluated` maps to total processed, `new_submitted` to succeeded count.

3. **Analysis Agent** (`agents/analysis_runner.py`, `agent_name: 'analysis-agent'`): Logs `summary` as `{ request_title, target_service, workspace, phases: {refine: "success", answer: "success", ...} }`. The phases object records pass/fail status of each pipeline step.

4. **Prompt Optimizer** (`agents/prompt_optimizer.py`, `agent_name: 'prompt-optimizer'`): Logs `summary` with varied shapes depending on action taken: `{ action: "enhanced", analysis: "...", changes: "...", last_run_new_ideas: N }` or `{ action: "rollback", reason: "..." }` or `{ action: "no_change", analysis: "..." }`.

**Frontend Data Loading**

When the app loads (after authentication), `showApp()` calls both `loadRequests()` and `loadRuns()`. The `loadRuns()` function (line 2038 in `index.html`) fetches the most recent 20 runs:

```javascript
async function loadRuns() {
    const { data, error } = await db
        .from('agent_runs')
        .select('*')
        .order('run_at', { ascending: false })
        .limit(20);

    if (error) {
        document.getElementById('runs-list').innerHTML =
            '<p style="color: var(--text-muted); font-size: 0.875rem;">Could not load agent runs.</p>';
        return;
    }

    renderRuns(data || []);
}
```

Realtime subscription at line 2159 auto-refreshes when the `agent_runs` table changes:
```javascript
.on('postgres_changes', { event: '*', schema: 'public', table: 'agent_runs' }, () => {
    loadRuns();
})
```

**Frontend Rendering -- The `renderRuns()` Function (line 2054-2144)**

This is the core function that needs modification. Here is its complete logic:

1. **Agent type detection**: Only two types are recognized by the UI: `requirements-agent` (via `isReqAgent = r.agent_name === 'requirements-agent'`) and everything else treated as "Discovery Agent". The agents `analysis-agent` and `prompt-optimizer` are NOT specifically handled -- they all fall through to the "Discovery Agent" label and metrics display. This is a pre-existing gap.

2. **Agent label**: Only "Requirements Agent" or "Discovery Agent" -- no label for analysis-agent or prompt-optimizer.

3. **Metrics display**: For requirements-agent, shows Processed/Generated/Failed counts. For everything else, shows Evaluated/Submitted/Duplicates/Searches.

4. **Error display**: If `r.errors` has entries, they are rendered as a red `<div class="run-errors">` below the agent label. This is the only "notes" display for failed/errored runs.

5. **Expandable detail section**: Only rendered if `r.summary` exists AND certain conditions:
   - For requirements-agent: shows succeeded items and failed items with error messages
   - For non-requirements-agent: shows competitor gaps and duplicates skipped
   - For analysis-agent and prompt-optimizer: since `isReqAgent` is false and `!isReqAgent` is true, the code looks for `r.summary.competitor_research` and `r.summary.duplicates` -- fields that analysis-agent and prompt-optimizer do NOT have in their summary. So **these agents produce NO expandable detail section** even when successful.

6. **The key gap**: When a discovery agent run succeeds (status='success', errors=[]), the user sees: a green dot, date, "Discovery Agent" label, and the numeric metrics. They can click to expand and see competitor gaps / duplicates. But there is no **narrative summary** -- e.g., "Discovered 7 new extension ideas including GCP Dataproc and SAP Datasphere" or "Rolled back prompt after 0 new ideas, then enhanced with 8 changes". For analysis-agent and prompt-optimizer runs, the situation is worse: there is literally nothing to expand.

**HTML Structure for Run Cards**

The HTML for each run card (line 2131-2142):
```html
<div class="run-card" onclick="toggleRunDetail(${i})">
    <div class="run-status-dot ${r.status}"></div>
    <div class="run-info">
        <div class="run-date">${timeStr}</div>
        <div class="run-agent">${agentLabel}</div>
        ${errHtml}   <!-- only shown for errors -->
    </div>
    <div class="run-metrics">${metricsHtml}</div>
    ${detailHtml}   <!-- expandable detail, hidden by default -->
</div>
```

**CSS for Run Cards** (lines 600-891 in `index.html`):
- `.run-card`: flex layout, padding, background, border, margin
- `.run-status-dot`: 10px colored circle (green/yellow/red based on status)
- `.run-info .run-date`: 0.875rem font, bold
- `.run-info .run-agent`: 0.75rem, muted color
- `.run-errors`: 0.75rem, red text, margin-top 0.25rem
- `.run-detail`: hidden by default, shown via `.open` class toggle
- `.run-summary-list`: styled list with green `+` or red `!` bullets

### What Needs to Change for This Task

The task requires adding visible notes/summary for successful agent runs. There are two complementary approaches needed:

**Backend (Python agents): Generate human-readable notes**

The agents already log structured `summary` JSONB but don't include a human-readable narrative. Each agent's `log_run()` call needs a `notes` field (or the existing `summary` JSONB needs a `notes` key) containing a brief text summary of what happened. The `agent_runs` table's `summary` JSONB column can hold this without schema changes.

Alternatively, a new TEXT column `notes` could be added to the `agent_runs` table. However, since `summary` is already JSONB and already stores arbitrary data, the simpler approach is to add a `notes` key to the summary JSONB. This avoids a database migration.

Agent-specific notes content should be:

- **Discovery Agent**: "Evaluated {N} candidates. Submitted {N} new ideas: {titles}. Skipped {N} duplicates, {N} below threshold. {Competitor gaps if any}."
- **Requirements Agent**: "Generated requirements for {N} services: {titles}. {N} failed."
- **Analysis Agent**: "Analyzed {title} ({target_service}). Phases: {phase results}. Workspace: {path}."
- **Prompt Optimizer**: "Action: {action}. {analysis summary if available}."

**Frontend (index.html): Display notes for all run types**

The `renderRuns()` function needs to:
1. Recognize all four agent types (not just two)
2. Display a human-readable notes line for successful runs (similar to how `errHtml` shows errors)
3. Ideally show notes from `r.summary.notes` if available, or generate a client-side summary from the existing summary structure as a fallback for historical runs

For the notes display, a new element could be added to the `.run-info` div, styled similarly to `.run-errors` but in a neutral or green color.

### Technical Reference Details

#### File Locations

- **Web interface (ALL frontend code)**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/index.html`
  - CSS for agent runs: lines 587-891
  - HTML container: lines 1164-1168
  - `loadRuns()`: lines 2038-2052
  - `renderRuns()`: lines 2054-2144 (THE MAIN FUNCTION TO MODIFY)
  - `toggleRunDetail()`: lines 2146-2149
  - `escapeHtml()`: lines 1814-1819

- **Discovery Agent**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/runner.py`
  - `log_run()` call: lines 344-361 (success case), lines 298-306 (failure case)

- **Requirements Agent**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/requirements_runner.py`
  - `log_run()` call: lines 470-489

- **Analysis Agent**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/analysis_runner.py`
  - `log_run()` call: lines 727-738

- **Prompt Optimizer**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/prompt_optimizer.py`
  - Multiple `log_run()` calls at lines 323-328, 359-365, 390-396, 410-417, 426-432, 454-466

- **Database schema**: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/supabase-agent-runs.sql`

#### Component Interfaces & Signatures

**Python agents -- `log_run()` method** (identical interface across all agents):
```python
def log_run(self, run_data: dict) -> int:
    """POST to /rest/v1/agent_runs. Returns HTTP status code."""
```

The `run_data` dict maps directly to the `agent_runs` table columns. The `summary` key accepts any JSON-serializable dict.

**Frontend -- Key functions:**
```javascript
async function loadRuns()                // Fetches from Supabase, calls renderRuns
function renderRuns(runs: Array<Object>) // Renders run cards into #runs-list
function toggleRunDetail(index: number)  // Toggles .open class on detail section
function escapeHtml(str: string): string // XSS-safe text escaping
```

#### Data Structures -- Summary JSONB by Agent Type

**Discovery Agent `summary`:**
```json
{
  "competitor_research": { "control_m": { "integrations_found": [...], "gaps_flagged": [...] }, ... },
  "below_threshold": [{ "title": "...", "target_service": "...", "priority_score": N }],
  "duplicates": [{ "title": "...", "target_service": "...", "reason": "duplicate" }]
}
```

**Requirements Agent `summary`:**
```json
{
  "succeeded": [{ "title": "...", "path": "/path/to/requirements.md" }],
  "failed": [{ "title": "...", "error": "error message" }]
}
```

**Analysis Agent `summary`:**
```json
{
  "request_title": "dbt Cloud – Trigger & Monitor...",
  "target_service": "dbt Cloud",
  "workspace": "/Users/.../ue-workspaces/ue-dbt-cloud",
  "phases": { "refine": "success", "answer": "success", "compose": "success", "design": "success" }
}
```

**Prompt Optimizer `summary`:**
```json
{
  "action": "enhanced|rollback|no_change|rejected|forced_rollback|enhancement_failed",
  "analysis": "Multi-line text analysis...",
  "changes": "Numbered list of changes...",
  "last_run_new_ideas": 7,
  "reason": "0 new ideas from last run"
}
```

#### CSS Classes Available for Reuse

- `.run-errors` -- red 0.75rem text, already used for error display. A parallel `.run-notes` class could be created for success notes.
- `.run-detail` / `.run-detail.open` -- expandable section (hidden/shown via click)
- `.run-summary-list` -- styled list container with `h4` heading and `li` items
- `.badge-*` -- colored pill badges for statuses

#### Pre-existing Issues to Be Aware Of

1. The agent label logic only handles `requirements-agent` vs everything else. Analysis agent runs show as "Discovery Agent" with discovery metrics. Prompt optimizer runs similarly show incorrect metrics. Fixing the agent label/metrics for all four agent types would be a natural part of this task, though it's technically an enhancement beyond the stated scope.

2. The `renderRuns` detail section for non-requirements agents looks for `competitor_research` and `duplicates` -- fields specific to the discovery agent. Analysis agent and prompt optimizer runs that are successful will have empty detail sections.

3. No database migration is needed if notes are stored inside the existing `summary` JSONB column. If a new column is preferred, an ALTER TABLE statement would be needed (no formal migration system -- SQL is run manually in Supabase Dashboard).

#### Implementation Strategy Recommendation

**Minimal approach (frontend-only, no agent changes):**
Generate the notes text client-side from the existing `summary` JSONB structure. This works for all historical and future runs without touching the Python agents. The `renderRuns` function would:
- Detect all four agent types by `agent_name`
- Build a human-readable notes string from the structured summary
- Display it in a new `.run-notes` element alongside (or below) the error display

**Full approach (frontend + backend):**
1. Add a `notes` key to each agent's `summary` JSONB when logging runs (4 Python files to modify)
2. Update `renderRuns()` to display `r.summary?.notes` when present
3. Fall back to generating notes client-side from structured summary data for historical runs

The frontend-only approach is recommended as the first step since it provides immediate value for all existing run data without needing to redeploy agents.

## User Notes
<!-- Any specific notes or requirements from the developer -->

## Work Log
<!-- Updated as work progresses -->
- [YYYY-MM-DD] Started task, initial research
