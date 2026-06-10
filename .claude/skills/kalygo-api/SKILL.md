---
name: kalygo-api
description: >
  Know-how for working with the Kalygo platform API (FastAPI backend). Use this skill
  whenever the user mentions Kalygo, wants to call any of its API endpoints, needs to
  construct requests for agents, email campaigns, email templates, contacts, contact lists,
  email events, credentials, prompts, similarity search, vector stores, or tool approvals.
  Also trigger when building any workflow that touches Kalygo's campaign or email systems.
---

# Kalygo API Skill

This skill provides endpoint reference and usage patterns for the Kalygo FastAPI backend.

## Full OpenAPI spec

The complete spec is at `references/openapi.json` relative to this skill directory.
Read it when you need exact schema shapes, enum values, or full parameter lists.

## Endpoint Index

### Auth

| Method | Path                       | Purpose                                         |
| ------ | -------------------------- | ----------------------------------------------- |
| GET    | `/api/auth/me`             | Get current user info                           |
| POST   | `/api/auth/request-code`   | Step 1 OTP login (sends 6-digit code)           |
| POST   | `/api/auth/verify-code`    | Step 2 OTP login (issues JWT cookie)            |
| GET    | `/api/auth/validate-token` | Validate bearer token (header: `authorization`) |
| DELETE | `/api/auth/log-out`        | Logout                                          |

### Email Templates

| Method | Path                                 | Purpose                                    |
| ------ | ------------------------------------ | ------------------------------------------ |
| GET    | `/api/email-templates/`              | List templates (optional `?search=`)       |
| POST   | `/api/email-templates/`              | Create template                            |
| GET    | `/api/email-templates/{template_id}` | Get template                               |
| PATCH  | `/api/email-templates/{template_id}` | Update template (subject, html, variables) |
| DELETE | `/api/email-templates/{template_id}` | Delete template                            |

**Template variables** use `{{variable_name}}` tokens in `subject_template` and `html_template`.
Variables are described in the `variables` array using `TemplateVariable` objects (`name`, `label`, `default`, `required`, `scope`).
`scope` is `campaign` (value supplied per-send in the request `variables`), `contact`
(resolved from the contact record, e.g. `first_name`), or `system` (backend-injected,
e.g. `RATING_BASE_URL`). **Templates are immutable** — to vary content, pass values to
`POST /api/emails/send`, do not mutate or clone the template.

### Email Campaigns

| Method   | Path                                          | Purpose                                                      |
| -------- | --------------------------------------------- | ------------------------------------------------------------ |
| GET      | `/api/email-campaigns/`                          | List campaigns (filter: `status`, `search`)                  |
| POST     | `/api/email-campaigns/`                          | Create campaign (grouping tag — template/content optional)   |
| GET      | `/api/email-campaigns/{campaign_id}`             | Get campaign                                                 |
| PATCH    | `/api/email-campaigns/{campaign_id}`             | Update campaign (name, status, list)                         |
| DELETE   | `/api/email-campaigns/{campaign_id}`             | Delete campaign                                              |
| GET      | `/api/email-campaigns/{campaign_id}/unsent`      | Contacts not yet sent for this campaign (resume helper)      |
| POST     | `/api/email-campaigns/{campaign_id}/send`        | Legacy server-side fan-out (renders stored template)         |

Campaign statuses: `draft`, `active`, `paused`, `completed`.
The campaign is a **grouping/correlation tag**; `email_template_id` and `contact_list_id`
are optional. Content is **not** stored on the campaign — it's passed per send.

### Sending email — `POST /api/emails/send` (the primitive)

This is the preferred send path. It renders an **immutable** template with request-supplied
`variables` (+ per-contact personalization + system tokens) and delivers to one recipient.

```
POST /api/emails/send
{
  "campaign_id": 123,            // required — correlation tag (must exist)
  "template_id": 6,              // required — immutable template to render
  "variables": {                 // optional — campaign-scoped content values
    "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..."
  },
  "recipient": { "contact_id": 42 },  // required — {contact_id} or {email}
  "credential_id": 30,           // required — stored AWS_SES credential
  "dry_run": false               // optional — validate required variables, don't send
}
```

Response (`SendEmailResponse`):

```json
{ "campaign_id": 123, "contact_id": 42, "tracking_id": "uuid",
  "status": "sent", "event_id": 9001 }
```

- `status`: `sent` | `skipped_duplicate` | `validated` (dry_run).
- **Idempotent**: a duplicate `(campaign_id, contact_id)` no-ops with `skipped_duplicate`.
- **Resumable**: to send to a whole list, loop its contacts calling this per contact; a
  crashed loop resumes by re-running and sending only `GET …/unsent` contacts.
- The backend generates a per-contact `tracking_id` and injects `RATING_BASE_URL`.

The older `POST /api/email-campaigns/{campaign_id}/send` (server-side fan-out over the
campaign's stored template) still exists for back-compat; prefer the primitive above.

### Email Events

| Method | Path                           | Purpose                                                                     |
| ------ | ------------------------------ | --------------------------------------------------------------------------- |
| GET    | `/api/email-events/`           | List events (filter: `campaign_id`, `event_type`, `contact_id`, date range) |
| GET    | `/api/email-events/stats`      | Aggregated counts per event type (filter by `campaign_id`)                  |
| POST   | `/api/email-events/`           | Record a single event                                                       |
| POST   | `/api/email-events/bulk`       | Record multiple events atomically                                           |
| PATCH  | `/api/email-events/{event_id}` | Update event_metadata                                                       |

Event types: `send`, `send_to_ses`, `delivery`, `open`, `bounce`, `complaint`, `click`, `other`

**Rating events** arrive as `click` events (or `other`) via the `/t/r/{tracking_id}/{rating}` tracking pixel.
To retrieve ratings for a campaign: filter `GET /api/email-events/` with `campaign_id=X&event_type=click`
and inspect `event_metadata` for the rating value (typically `{"rating": N}`).

### Tracking

| Method | Path                          | Purpose                               |
| ------ | ----------------------------- | ------------------------------------- |
| GET    | `/t/o/{tracking_id}`          | Track email open (returns 1x1 GIF)    |
| GET    | `/t/r/{tracking_id}/{rating}` | Track star rating click (rating: 1–5) |

To embed rating links in an HTML template:

```html
<a href="{{base_url}}/t/r/{{tracking_id}}/1">⭐</a>
<a href="{{base_url}}/t/r/{{tracking_id}}/2">⭐⭐</a>
<a href="{{base_url}}/t/r/{{tracking_id}}/3">⭐⭐⭐</a>
<a href="{{base_url}}/t/r/{{tracking_id}}/4">⭐⭐⭐⭐</a>
<a href="{{base_url}}/t/r/{{tracking_id}}/5">⭐⭐⭐⭐⭐</a>
```

### Contacts & Contact Lists

| Method | Path                                                | Purpose                                    |
| ------ | --------------------------------------------------- | ------------------------------------------ |
| GET    | `/api/contacts/`                                    | List contacts (filter: `status`, `search`) |
| POST   | `/api/contacts/`                                    | Create contact                             |
| GET    | `/api/contact-lists/`                               | List contact lists                         |
| POST   | `/api/contact-lists/`                               | Create contact list                        |
| GET    | `/api/contact-lists/{list_id}`                      | Get list with members                      |
| POST   | `/api/contact-lists/{list_id}/members/`             | Add single contact to list                 |
| POST   | `/api/contact-lists/{list_id}/members/bulk`         | Bulk add contacts                          |
| DELETE | `/api/contact-lists/{list_id}/members/{contact_id}` | Remove member                              |

### Agents

| Method | Path                     | Purpose             |
| ------ | ------------------------ | ------------------- |
| GET    | `/api/agents/`           | List agents         |
| POST   | `/api/agents/`           | Create agent        |
| GET    | `/api/agents/{agent_id}` | Get agent           |
| PUT    | `/api/agents/{agent_id}` | Update agent config |
| DELETE | `/api/agents/{agent_id}` | Delete agent        |

Agent config shape (v4):

```json
{
  "schema": "agent_config",
  "version": 4,
  "data": {
    "systemPrompt": "You are a helpful assistant.",
    "model": { "provider": "openai", "model": "gpt-4o-mini" },
    "tools": []
  }
}
```

Supported providers: `openai`, `anthropic`, `google`, `ollama`

### Tool Approvals

| Method | Path                               | Purpose                                                                      |
| ------ | ---------------------------------- | ---------------------------------------------------------------------------- |
| GET    | `/api/tool-approvals/`             | List approvals (default: `status=pending`)                                   |
| POST   | `/api/tool-approvals/{id}/approve` | Approve and execute (optional overrides for to_email/subject/body/html_body) |
| POST   | `/api/tool-approvals/{id}/reject`  | Reject without executing                                                     |
| POST   | `/api/tool-approvals/{id}/preview` | Preview email without sending to real recipient                              |

### Credentials

| Method | Path                         | Purpose                                                          |
| ------ | ---------------------------- | ---------------------------------------------------------------- |
| GET    | `/api/credentials/`          | List credentials (metadata only)                                 |
| POST   | `/api/credentials/flexible`  | Create flexible credential (api_key, db_connection, oauth, etc.) |
| GET    | `/api/credentials/{id}/full` | Get credential with decrypted data                               |
| PUT    | `/api/credentials/{id}/full` | Update flexible credential                                       |

Supported `credential_type` values (ServiceName enum):
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_GEMINI_API_KEY`, `PINECONE_API_KEY`,
`ELEVENLABS_API_KEY`, `SUPABASE`, `AWS_SES`, `GOOGLE_OAUTH`, `GOOGLE_GMAIL_SMTP`

### Prompts (Prompt Library)

| Method | Path                | Purpose                                      |
| ------ | ------------------- | -------------------------------------------- |
| GET    | `/api/prompts/`     | List prompts                                 |
| POST   | `/api/prompts/`     | Create prompt (auto-indexed in Pinecone)     |
| PUT    | `/api/prompts/{id}` | Update prompt (re-embeds if content changed) |
| DELETE | `/api/prompts/{id}` | Delete prompt + its Pinecone vector          |

### Similarity Search

| Method | Path                              | Purpose                                                                        |
| ------ | --------------------------------- | ------------------------------------------------------------------------------ |
| POST   | `/api/similarity-search/search`   | Vector search (`query`, `top_k`, `similarity_threshold`, `?namespace=prompts`) |
| GET    | `/api/similarity-search/kb-stats` | Index/namespace stats                                                          |

## Authentication

Two auth modes are supported. Pick based on the endpoint:

**API key** — `X-API-Key: kalygo_live_…` header. This is the preferred mode for
server-to-server / scripted use (e.g. the email-optimization loop). It works for
the data-plane endpoints: email-templates, email-campaigns (incl. `/send`),
email-events (incl. `/stats`), contacts, and contact-lists.

Do NOT pass the API key as `Authorization: Bearer …` — that path runs the token
through a JWT decoder and fails with `"Not enough segments"`.

**JWT session** — obtained via the OTP flow (`/api/auth/request-code` →
`/api/auth/verify-code`, which sets a session cookie). Required for endpoints
that the API key cannot reach: `/api/auth/me`, `/api/auth/validate-token`,
`/api/credentials/` (decrypts secrets), `/api/agents/`, and `/api/prompts/`.
Pass as either the session cookie or `Authorization: Bearer <jwt>`.

The OpenAPI spec only documents the JWT scheme — the X-API-Key path is real but
undocumented there, so don't be misled when reading `components.securitySchemes`.

## Common Patterns

### Creating and sending a campaign (full sequence for the optimization loop)

Templates are immutable; per-iteration content is passed as `variables` per send.

```
# 1. Create the campaign grouping tag (no template/content stored on it)
POST /api/email-campaigns/
{ "name": "email-opt-branch-A-iter-3", "contact_list_id": 7 }
→ returns { "id": 123, ... }

# 2. Dry-run one send to validate template + required variables before touching anyone
POST /api/emails/send
{ "campaign_id": 123, "template_id": 42, "variables": {...}, "recipient": {"contact_id": 1},
  "credential_id": 5, "dry_run": true }

# 3. Fan out over the list: loop contacts, send the immutable template + variables to each
for each contact in list 7:
  POST /api/emails/send
  { "campaign_id": 123, "template_id": 42, "variables": {...},
    "recipient": {"contact_id": <id>}, "credential_id": 5 }
→ each returns { "status": "sent" | "skipped_duplicate", "tracking_id": "uuid", ... }

# 4. Resume after a crash (idempotent): re-fetch the remainder and continue
GET /api/email-campaigns/123/unsent?contact_list_id=7   → { "remaining": [...] }
```

The backend generates a unique `tracking_id` per contact so `/t/r/` rating events
can be correlated back to the specific contact-campaign pair. Dedup on
`(campaign_id, contact_id)` makes re-running step 3 safe — already-sent contacts no-op.

### Querying rating events for a campaign

```
GET /api/email-events/?campaign_id=123&event_type=click&limit=500
```

Inspect each `event_metadata` for `{"rating": N}`. Deduplicate by `contact_id`.

### Getting aggregate send count

```
GET /api/email-events/stats?campaign_id=123
```

Returns `{ "send": N, "delivery": N, "open": N, "click": N, ... }`
Use `stats.send` as the denominator for participation rate calculations.
