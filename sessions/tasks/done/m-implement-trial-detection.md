---
name: m-implement-trial-detection
branch: feature/trial-detection
status: complete
created: 2026-03-24
---

# Add Free Trial Account Detection to Discovery Agent

## Problem/Goal
The discovery agent evaluates candidate services for UAC Universal Extension integrations, but doesn't check whether a free trial account is available. Testing is critical for writing integrations — without a trial account (except Azure, AWS, and GCP where the team already has accounts), a customer volunteer is needed for testing. The agent should detect trial availability and surface it in the web UI so candidates can be prioritized accordingly.

## Success Criteria
- [x] Discovery agent checks whether each candidate service offers a free trial account
- [x] Trial availability is factored into the priority score (+1 boost for trial/account available)
- [x] Azure, AWS, and GCP services are automatically marked as "account available"
- [x] Trial availability info is stored in the request data (`trial_available` column)
- [x] Web UI displays trial availability status (column, badges, filter, detail view)

## Context Manifest

### Architecture Overview

This project is the **Extension Requirements Tracker** -- a system for discovering, evaluating, and tracking Universal Extension integration ideas for Stonebranch's Universal Automation Center (UAC). It consists of three layers:

1. **Discovery Agent** (`agents/runner.py`) -- Python script using Claude CLI with web search to discover, score, deduplicate, and submit extension ideas to Supabase.
2. **Supabase Backend** -- PostgreSQL database with tables `requests`, `request_comments`, `agent_runs`, and `admins`.
3. **Web UI** (`index.html`) -- Single-page GitHub Pages app for viewing, voting, filtering, and managing requests.

### Files Modified

- `supabase-trial-available.sql` -- Migration adding `trial_available` column with CHECK constraint
- `agents/research_prompt.py` -- TRIAL AVAILABILITY section and `trial_available` in JSON output format
- `agents/runner.py` -- Cloud provider auto-detection, trial normalization, +1 priority boost, trial field in payload
- `index.html` -- Trial column, badges, filter dropdown, detail view metadata

## Work Log

### 2026-03-24
#### Completed
- Created task with detailed context manifest and implementation plan

### 2026-03-25
#### Completed
- Created SQL migration `supabase-trial-available.sql` adding `trial_available` column (values: yes, no, account_available, unknown) with CHECK constraint
- Updated `agents/research_prompt.py` with TRIAL AVAILABILITY research section and `trial_available` field in JSON output examples
- Updated `agents/runner.py`:
  - Cloud provider auto-detection (AWS, Azure, GCP marked as `account_available`)
  - Trial value normalization (boolean/string to DB enum)
  - +1 priority score boost for ideas with trial or account available
  - `trial_available` field included in Supabase request payload
- Updated `index.html`:
  - Trial column in request list table
  - Color-coded badges (green "Trial", green "Account", gray "No Trial", dim "Unknown")
  - Trial availability filter dropdown
  - Trial status in detail view metadata

#### Decisions
- Used code-level +1 priority boost (deterministic and auditable) rather than prompt-level scoring guidance
- Applied boost only to ideas already in `new_ideas` (avoids complexity of promoting below-threshold items)

## Next Steps
- Run the SQL migration on Supabase production database
- Verify end-to-end with a discovery agent run
- Task complete -- all success criteria met
