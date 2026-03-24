---
name: m-implement-trial-detection
branch: feature/trial-detection
status: in-progress
created: 2026-03-24
---

# Add Free Trial Account Detection to Discovery Agent

## Problem/Goal
The discovery agent evaluates candidate services for UAC Universal Extension integrations, but doesn't check whether a free trial account is available. Testing is critical for writing integrations — without a trial account (except Azure, AWS, and GCP where the team already has accounts), a customer volunteer is needed for testing. The agent should detect trial availability and surface it in the web UI so candidates can be prioritized accordingly.

## Success Criteria
- [ ] Discovery agent checks whether each candidate service offers a free trial account
- [ ] Trial availability is factored into the priority score (higher score if trial available)
- [ ] Azure, AWS, and GCP services are automatically marked as "account available"
- [ ] Trial availability info is stored in the request data
- [ ] Web UI displays trial availability status for each request

## Context Manifest

### Architecture Overview

This project is the **Extension Requirements Tracker** -- a system for discovering, evaluating, and tracking Universal Extension integration ideas for Stonebranch's Universal Automation Center (UAC). It consists of three layers:

1. **Discovery Agent** (`agents/runner.py`) -- a Python script that uses Claude CLI with web search to discover new extension ideas, score them, deduplicate them against existing entries, and submit them to Supabase.
2. **Supabase Backend** -- a PostgreSQL database (hosted on Supabase) with tables `requests`, `request_comments`, `agent_runs`, and `admins`. The `requests` table is the central data store for all extension ideas.
3. **Web UI** (`index.html`) -- a single-page GitHub Pages app that renders the requests table, supports voting, filtering, sorting, detail views, comments, and agent run history.

There are also downstream agents (requirements_runner.py, analysis_runner.py, prompt_optimizer.py) that process requests further, but they are not the primary concern for this task. The discovery agent is the entry point where trial detection needs to be added.

---

### How the Discovery Agent Currently Works

When the discovery agent runs (daily via cron at midnight, see `agents/run-discovery-cron.sh`), it follows this flow:

**Step 1 -- Authentication**: The `main()` function in `runner.py` creates a `SupabaseClient` instance and calls `sign_in()` with credentials from `config.py` (`AGENT_EMAIL = "huseyim+agent@gmail.com"`, `AGENT_PASSWORD = "Ext$ifre23!2"`). This authenticates against Supabase's GoTrue auth endpoint and stores an access token and user ID.

**Step 2 -- Fetch existing requests**: `db.fetch_existing_requests()` calls `GET /rest/v1/requests?select=title,target_service` to retrieve all existing request titles and target services. This is used for deduplication.

**Step 3 -- Claude research**: `call_claude_research(existing_requests)` builds a massive prompt by concatenating `SYSTEM_PROMPT` (from `research_prompt.py`) with the output of `build_research_prompt(existing_requests)`. The prompt instructs Claude to:
- Search the web across 10 research tracks (A through J): competitor libraries, AWS/Azure/GCP services, SaaS/DevOps tools, Linux/Windows utilities, internal UC features, MLOps, AI agentic platforms, and data governance platforms.
- Score each candidate on 5 dimensions (market_demand, automation_fit, api_maturity, differentiator, effort_estimate), each 1-5.
- Compute `priority_score = round(average(all 5) * 4)` -- max 20.
- Only include ideas with `priority_score >= 10`.
- Map priority_score to priority: 16-20 = "critical", 12-15 = "high", 10-11 = "medium".

The Claude CLI is invoked as: `claude -p --model claude-sonnet-4-6 --allowedTools WebSearch,WebFetch`

The expected JSON output from Claude has this structure:
```json
{
  "candidates_evaluated": 62,
  "new_ideas": [
    {
      "title": "AWS Bedrock - Invoke Foundation Model",
      "target_service": "AWS Bedrock",
      "integration_type": "rest_api",
      "priority": "critical",
      "description": "...",
      "rationale": "...",
      "priority_score": 17,
      "scores": {
        "market_demand": 5,
        "automation_fit": 4,
        "api_maturity": 4,
        "differentiator": 5,
        "effort_estimate": 4
      },
      "proposed_actions": ["invoke_model", "get_invocation_status"],
      "source_urls": ["https://aws.amazon.com/bedrock/"],
      "competitor_gap": true
    }
  ],
  "below_threshold": [
    {
      "title": "Some Niche Tool",
      "target_service": "Niche Tool",
      "priority_score": 7
    }
  ],
  "competitor_research": {
    "control_m": { "integrations_found": [...], "gaps_flagged": [...] },
    ...
  },
  "searches_performed": 24,
  "errors": []
}
```

**Step 4 -- Deduplication**: `deduplicate(new_ideas, existing)` compares each idea's title and target_service (case-insensitive) against existing requests AND the hardcoded `EXISTING_EXTENSIONS` list (141 extensions). Matches go to `duplicates`, non-matches go to `to_submit`.

**Step 5 -- Submission**: For each idea in `to_submit`, `build_request_payload(idea, user_id)` constructs the Supabase row. The payload includes:
```python
{
    "title": idea["title"],
    "target_service": idea.get("target_service", ""),
    "integration_type": idea.get("integration_type", "rest_api"),
    "status": "new",
    "priority": idea.get("priority", "medium"),
    "description": description.strip(),  # Formatted multi-line string with scores
    "api_info": api_info,  # Source URLs
    "requested_by": user_id,
    "requested_by_name": "Discovery Agent",
    "requested_by_email": AGENT_EMAIL,
}
```

The description field is a formatted string that includes: the raw description, rationale, individual scores (formatted as "Market Demand: 4/5"), priority score ("Priority Score: 17/20"), proposed actions, and competitor gap status. This is currently all embedded in the description text -- there are no separate structured columns for scores, competitor_gap, etc.

**Step 6 -- Logging**: An `agent_runs` entry is inserted with counts of evaluated/submitted/duplicated/below-threshold candidates, plus a summary JSON blob containing competitor_research, below_threshold items, and duplicate details.

---

### The `requests` Table Schema

The current schema (from `supabase-setup.sql`) has these columns:

```sql
CREATE TABLE public.requests (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    title TEXT NOT NULL,
    target_service TEXT NOT NULL,
    integration_type TEXT DEFAULT 'rest_api'
        CHECK (integration_type IN ('rest_api', 'cli', 'sdk', 'database', 'message_queue', 'other')),
    status TEXT DEFAULT 'new'
        CHECK (status IN ('new', 'researching', 'requirements_ready', 'in_review', 'approved', 'rejected')),
    priority TEXT DEFAULT 'medium'
        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    description TEXT,
    api_info TEXT,
    requirements_url TEXT,
    requirements_content TEXT,  -- Added later via ALTER TABLE
    requested_by UUID REFERENCES auth.users(id),
    requested_by_email TEXT,
    requested_by_name TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

There is also a `votes` column (INT, added after the initial schema -- it appears in the UI query `select('id,title,...,votes')` but not in the original SQL setup script). The `analysis_complete` and `accepted` statuses were also added after the initial schema (they appear in the UI status filter but not in the original CHECK constraint).

**Key observation**: There is currently NO column for trial/account availability. A new column needs to be added (e.g., `trial_available TEXT` with CHECK constraint for values like `'yes'`, `'no'`, `'account_available'`, `'unknown'`). This will require an `ALTER TABLE` migration SQL.

---

### How the Web UI Renders Requests

The web UI (`index.html`) is a single HTML file with embedded CSS and JavaScript. It uses the Supabase JS client (`@supabase/supabase-js@2`) loaded from CDN.

**List View**: The `loadRequests()` function fetches all requests (excluding `requirements_content` for performance) and stores them in `allRequests[]`. The `renderRequests()` function generates an HTML table with columns: Votes, Title, Service, Status, Priority, Type, Updated, Actions.

The table row rendering happens at line ~1458 in the `renderRequests()` function:
```javascript
container.innerHTML = `
    <table>
        <thead>
            <tr>
                <th>Votes</th>
                <th>Title</th>
                <th>Service</th>
                <th>Status</th>
                <th>Priority</th>
                <th>Type</th>
                <th>Updated</th>
                <th>Actions</th>
            </tr>
        </thead>
        <tbody>
            ${filtered.map(r => `
                <tr class="clickable-row" onclick="showDetail('${r.id}')">
                    <td>...</td>  // Votes with up/down buttons
                    <td><strong>${escapeHtml(r.title)}</strong></td>
                    <td>${escapeHtml(r.target_service || '-')}</td>
                    <td><span class="badge badge-${r.status}">...</span></td>
                    <td><span class="priority-dot priority-${r.priority}"></span>...</td>
                    <td>${formatIntegrationType(r.integration_type)}</td>
                    <td>...</td>
                    <td>... quick action buttons ...</td>
                </tr>
            `).join('')}
        </tbody>
    </table>`;
```

**Detail View**: The `showDetail(id)` function fetches the full record (including `requirements_content`) and renders a detail page with metadata items: Status, Priority, Target Service, Integration Type, Requested By, Created. The metadata is rendered as a grid of label/value pairs in `detail-meta`.

**Filters**: The toolbar provides search, status filter, priority filter, and sort select. These call `renderRequests()` on change.

**Loading query**: `db.from('requests').select('id,title,target_service,integration_type,status,priority,description,api_info,requirements_url,requested_by,requested_by_email,requested_by_name,created_at,updated_at,votes')` -- this explicit field list must be updated to include the new trial field.

---

### Where Trial Detection Fits In -- Implementation Plan

#### 1. Database: New Column

Add a new column to the `requests` table. A suggested approach:
```sql
ALTER TABLE public.requests ADD COLUMN IF NOT EXISTS trial_available TEXT DEFAULT 'unknown'
    CHECK (trial_available IN ('yes', 'no', 'account_available', 'unknown'));
```

Values:
- `'yes'` -- Free trial is available for this service
- `'no'` -- No free trial detected
- `'account_available'` -- Team already has an account (Azure, AWS, GCP)
- `'unknown'` -- Not yet evaluated

This migration SQL should be saved alongside `supabase-requirements-content.sql` (the project keeps migration SQLs as standalone files in the repo root).

#### 2. Discovery Agent: Research Prompt Changes (`agents/research_prompt.py`)

The research prompt's SCORING section (around line 339) needs a new instruction telling Claude to also check for free trial availability. This should be added as part of the research instructions, not as a scoring dimension (to avoid disrupting the existing 5-dimension scoring formula).

Add a new field to the expected JSON output format: `"trial_available"` with values `true`/`false`/`"account_available"`. The prompt should instruct Claude to:
- Check each candidate service's website for free trial, developer tier, or freemium plan
- Auto-mark services on Azure, AWS, and GCP as having account access (since the team already has accounts)
- Record this in the output JSON

The relevant section in `research_prompt.py` is the OUTPUT FORMAT block (starting around line 362). The example JSON object for `new_ideas` items would gain a `"trial_available"` field. Also the `below_threshold` items could include this info.

**Critical**: The `build_research_prompt()` function (line 144) builds the prompt dynamically. It does NOT need changes for trial detection -- the trial instruction belongs in the static `SYSTEM_PROMPT` or in the research prompt template itself.

The cloud provider auto-detection should happen in the prompt itself (instructing Claude to mark Azure/AWS/GCP services as account_available) AND/OR as a post-processing step in the Python code (`build_request_payload` or a new function).

#### 3. Discovery Agent: Runner Changes (`agents/runner.py`)

**`build_request_payload()`** (line 217): Currently builds the description string and maps fields. Needs to:
- Extract `trial_available` from the idea dict
- Map Claude's boolean/string response to the DB enum values
- Include it in the payload dict
- Optionally add "Trial Available: Yes/No/Account Available" to the description text

**Post-processing for cloud providers**: After Claude returns results but before submission, add logic to auto-mark any idea whose `target_service` matches known cloud providers:
```python
TEAM_ACCOUNT_PROVIDERS = {"aws", "azure", "gcp", "google cloud", "amazon"}

def detect_account_available(target_service: str) -> str:
    service_lower = target_service.lower()
    for provider in TEAM_ACCOUNT_PROVIDERS:
        if provider in service_lower:
            return "account_available"
    return None  # let Claude's determination stand
```

This should override Claude's trial detection for these services.

**Priority score adjustment**: The task says trial availability should factor into priority scoring. Options:
- **Option A (prompt-level)**: Add trial availability as guidance in the scoring section -- "If a free trial is available, consider boosting the score by 1-2 points since testing is easier."
- **Option B (code-level)**: After Claude returns scores, add a bonus to `priority_score` for ideas with trial available. E.g., +1 or +2 points. This is more deterministic.
- **Option C (hybrid)**: Both. The prompt gives Claude awareness, and the code applies a consistent bonus.

Option B or C is recommended because it provides reliable, auditable scoring adjustments.

If implementing code-level scoring, it would go after `call_claude_research()` returns and before `deduplicate()`:
```python
# Adjust scores based on trial availability
for idea in research.get("new_ideas", []):
    trial = idea.get("trial_available")
    service_lower = idea.get("target_service", "").lower()

    # Auto-detect cloud provider accounts
    if any(p in service_lower for p in ["aws", "azure", "gcp", "google cloud", "amazon"]):
        idea["trial_available"] = "account_available"

    # Boost priority_score for trial availability
    if idea.get("trial_available") in (True, "yes", "account_available"):
        idea["priority_score"] = min(20, idea.get("priority_score", 0) + 1)
```

Note that boosting might push ideas from below_threshold into new_ideas, which adds complexity. For simplicity, the boost could apply only to ideas already in `new_ideas`.

#### 4. Web UI Changes (`index.html`)

**List query** (line 1372): Add `trial_available` to the select fields:
```javascript
.select('id,title,target_service,integration_type,status,priority,description,api_info,requirements_url,requested_by,requested_by_email,requested_by_name,created_at,updated_at,votes,trial_available')
```

**Table header** (line ~1447): Add a "Trial" column header between Type and Updated (or wherever makes sense).

**Table row** (line ~1458): Add a cell that displays the trial status, possibly with a visual indicator:
- `account_available` -> green badge "Account"
- `yes` -> green badge "Trial"
- `no` -> gray badge "No Trial"
- `unknown` -> dim text "Unknown"

**Detail view metadata** (line ~1695): Add a new `detail-meta-item` for trial availability.

**Filter** (optional): Add a trial availability filter dropdown alongside the existing status and priority filters.

---

### Existing Patterns to Follow

**Badge styling**: The UI uses CSS classes like `.badge-new`, `.badge-approved`, etc. with color-coded backgrounds. A similar pattern should be used for trial badges.

**Column in description**: Currently, the `build_request_payload()` function embeds structured data (scores, competitor gap, etc.) into the `description` TEXT field. Trial availability should be added to this text AND stored in the dedicated column for machine-readable filtering.

**SQL migrations**: The project stores migration SQL as standalone files in the repo root. Examples: `supabase-setup.sql`, `supabase-agent-runs.sql`, `supabase-requirements-content.sql`. Follow this pattern.

**Prompt modification**: The `research_prompt.py` file is managed by the prompt_optimizer agent (`prompt_optimizer.py`), which creates backups (`research_prompt.py.bak`) and logs changes to `prompt_changelog.md`. Manual edits are fine, but be aware the optimizer may later modify the prompt. Keep trial detection instructions clearly delineated.

---

### Technical Reference Details

#### Component Interfaces & Signatures

**runner.py functions:**
```python
def call_claude_research(existing_requests: list[dict], max_retries: int = 2) -> dict
def parse_json_output(text: str) -> dict
def deduplicate(new_ideas: list[dict], existing: list[dict]) -> tuple[list, list]
def build_request_payload(idea: dict, user_id: str) -> dict
```

**SupabaseClient methods (runner.py):**
```python
def sign_in(self, email: str, password: str) -> None
def fetch_existing_requests(self) -> list[dict]  # Returns [{title, target_service}, ...]
def insert_request(self, payload: dict) -> int  # Returns HTTP status code
def log_run(self, run_data: dict) -> int
```

**research_prompt.py exports:**
```python
SYSTEM_PROMPT: str  # System prompt for Claude
EXISTING_EXTENSIONS: list[str]  # 141 existing extension names
def build_research_prompt(existing_requests: list[dict]) -> str
```

#### Data Structures

**Claude output JSON -- new_ideas item (add trial_available):**
```json
{
  "title": "string",
  "target_service": "string",
  "integration_type": "rest_api|cli|sdk|database|message_queue|other",
  "priority": "critical|high|medium",
  "description": "string",
  "rationale": "string",
  "priority_score": 17,
  "scores": {"market_demand": 5, "automation_fit": 4, "api_maturity": 4, "differentiator": 5, "effort_estimate": 4},
  "proposed_actions": ["string"],
  "source_urls": ["string"],
  "competitor_gap": true,
  "trial_available": true  // NEW FIELD
}
```

**Supabase request payload (add trial_available):**
```python
{
    "title": str,
    "target_service": str,
    "integration_type": str,
    "status": "new",
    "priority": str,
    "description": str,
    "api_info": str | None,
    "requested_by": str,  # UUID
    "requested_by_name": "Discovery Agent",
    "requested_by_email": str,
    "trial_available": str,  # NEW: "yes"|"no"|"account_available"|"unknown"
}
```

#### Configuration Requirements

- No new environment variables needed
- No new dependencies needed
- Supabase database migration required (ALTER TABLE)

#### File Locations

- Discovery agent runner: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/runner.py`
- Research prompt: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/research_prompt.py`
- Agent config: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/config.py`
- Web UI: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/index.html`
- DB schema: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/supabase-setup.sql`
- Migration SQL (create new): `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/supabase-trial-available.sql`
- Agent runs SQL: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/supabase-agent-runs.sql`
- Cron wrapper: `/Users/h.gomleksizoglu/SE/scripts/ext_auto_requirement/agents/run-discovery-cron.sh`

#### Existing Extensions with Cloud Provider Names (for auto-detection reference)

These are existing extensions that contain Azure/AWS/GCP in their names (from the `EXISTING_EXTENSIONS` list). The auto-detect logic should match on the `target_service` field of new ideas, not existing extensions:
- AWS: "Amazon Bedrock", "Amazon EKS Jobs", "Amazon S3 File Transfer", "Amazon SQS Message/Monitor", "AWS Batch", "AWS CLI", "AWS EC2", "AWS ECS", "AWS EMR", "AWS Glue", "AWS Lambda", "AWS Mainframe Modernization", "AWS Step Functions"
- Azure: "Azure AZ CLI", "Azure Batch", "Azure Blob File Transfer", "Azure Data Factory", "Azure Kubernetes", "Azure Logic Apps", "Azure OpenAI", "Azure Synapse", "Azure Virtual Machines"
- GCP: "Google BigQuery", "Google Kubernetes Engine Jobs", "Google Vertex AI"

The auto-detection for "account_available" should match broadly on target_service containing: "aws", "amazon", "azure", "gcp", "google cloud".

## User Notes
<!-- Any specific notes or requirements from the developer -->

## Work Log
<!-- Updated as work progresses -->
- [YYYY-MM-DD] Started task, initial research
