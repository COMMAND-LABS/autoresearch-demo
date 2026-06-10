---
name: kalygo-api
description: >
  Endpoint reference and auth patterns for the Kalygo platform API (FastAPI backend),
  focused on the email pipeline this project uses: email templates, email campaigns,
  per-recipient sends, rating retrieval, contacts/contact-lists, and credentials. Use
  whenever the user mentions Kalygo or needs to call its email/campaign endpoints. The
  full spec for every other endpoint (agents, prompts, vector stores, tool approvals,
  payments, …) is in references/openapi.json.
---

# Kalygo API Skill

Endpoint reference for the Kalygo FastAPI backend, scoped to the email-optimization
pipeline. For anything outside that scope, read the complete spec at
`references/openapi.json` (exact schemas, enums, full parameter lists).

The Python helpers in the project's `ar_helpers.py` already wrap the calls below —
prefer them over hand-rolling requests.

## Authentication

**API key** (preferred for scripted use like this loop) — `X-API-Key: kalygo_live_…`
header. Works for the data-plane endpoints used here: email-templates, email-campaigns
(incl. `/ratings`, `/ratings/summary`, `/unsent`), emails/send, contacts, contact-lists.

Do NOT pass the API key as `Authorization: Bearer …` — that path runs it through a JWT
decoder and fails with `"Not enough segments"`. (The OpenAPI spec only documents the
JWT scheme; the `X-API-Key` path is real but undocumented there.)

**JWT session** — OTP flow (`/api/auth/request-code` → `/api/auth/verify-code`, sets a
cookie). Required only for endpoints the API key can't reach (`/api/auth/me`, decrypted
`/api/credentials/…/full`, agents, prompts).

## Email Templates

| Method | Path                                 | Purpose                              |
| ------ | ------------------------------------ | ------------------------------------ |
| GET    | `/api/email-templates/`              | List templates (optional `?search=`) |
| GET    | `/api/email-templates/{template_id}` | Get one template                     |

Templates use `{{variable_name}}` tokens in `subject_template` and `html_template`,
described by `TemplateVariable` objects (`name`, `label`, `default`, `required`, `scope`).
`scope` is `campaign` (value supplied per-send in the request `variables`), `contact`
(resolved from the contact record, e.g. `first_name`), or `system` (backend-injected,
e.g. `RATING_BASE_URL`). **Templates are immutable** — to vary content, pass values to
`POST /api/emails/send`; never mutate or clone the template. (Create/PATCH/DELETE exist
but are not used by the loop.)

## Email Campaigns

| Method | Path                                        | Purpose                                              |
| ------ | ------------------------------------------- | ---------------------------------------------------- |
| POST   | `/api/email-campaigns/`                     | Create a campaign (grouping tag; content NOT stored) |
| GET    | `/api/email-campaigns/{id}`                 | Get a campaign                                       |
| GET    | `/api/email-campaigns/{id}/unsent`          | Contacts not yet sent for this campaign (resume)     |
| GET    | `/api/email-campaigns/{id}/ratings/summary` | **Aggregate ratings** for the campaign               |
| GET    | `/api/email-campaigns/{id}/ratings`         | Individual rating rows (`?limit=`, `?min_rating=` …) |

The campaign is purely a **grouping/correlation tag**; `email_template_id` and
`contact_list_id` are optional and no content is stored on it — content rides in per
send. Statuses: `draft`, `active`, `paused`, `completed`.

## Sending — `POST /api/emails/send` (the primitive)

Renders an **immutable** template with request-supplied `variables` (+ per-contact
personalization + system tokens) and delivers to **one** recipient.

```
POST /api/emails/send
{
  "campaign_id": 123,            // required — correlation tag (must exist)
  "template_id": 6,              // required — immutable template to render
  "variables": { "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..." },  // campaign-scoped only
  "recipient": { "contact_id": 42 },   // required — {contact_id} (preferred) or {email}
  "credential_id": 30,           // required — stored AWS_SES credential
  "dry_run": false               // optional — validate required variables, don't send
}
→ { "campaign_id":123, "contact_id":42, "tracking_id":"uuid", "status":"sent", "event_id":9001 }
```

- `status`: `sent` | `skipped_duplicate` | `validated` (dry_run).
- **Idempotent / resumable**: a duplicate `(campaign_id, contact_id)` no-ops as
  `skipped_duplicate`. To send to a list, loop its contacts (or `GET …/unsent`) calling
  this per contact; a crashed loop just re-runs and sends only the remainder.
- The backend generates a per-contact `tracking_id` and injects `RATING_BASE_URL`, so do
  NOT supply `RATING_BASE_URL` yourself — a static value breaks rating attribution.
- `send_count` for the participation rate = the number of successful sends you made this
  iteration (`execute_campaign(...)["sent"]`).

A legacy server-side fan-out (`POST /api/email-campaigns/{id}/send`, renders a stored
template) exists for back-compat; prefer the primitive above.

## Ratings & tracking

Recipients rate by clicking a star link, which hits the tracker:

| Method | Path                          | Purpose                              |
| ------ | ----------------------------- | ------------------------------------ |
| GET    | `/t/o/{tracking_id}`          | Track open (returns 1×1 GIF)         |
| GET    | `/t/r/{tracking_id}/{rating}` | Track star rating click (rating 1–5) |

Those clicks are recorded as **ratings** keyed to the `(campaign, contact)` via
`tracking_id`. **Read them back from the campaign ratings endpoints, not from
email-events:**

```
GET /api/email-campaigns/{id}/ratings/summary
→ { campaign_id, total_ratings, average_rating, distribution, by_template }

GET /api/email-campaigns/{id}/ratings?limit=500
→ [ { rating, contact_id, tracking_id, created_at }, ... ]
```

Use `total_ratings` as `num_ratings` and `average_rating` as `avg_rating`.

> Note: `/api/email-events/` is the raw SES delivery ledger (`send`, `delivery`,
> `open`, `bounce`, `complaint`, `click`). Ratings do **not** live there — don't try to
> reconstruct them from `click` events. Use the ratings endpoints above.

## Contacts & Contact Lists

| Method | Path                                    | Purpose                      |
| ------ | --------------------------------------- | ---------------------------- |
| GET    | `/api/contact-lists/`                   | List contact lists           |
| GET    | `/api/contact-lists/{list_id}`          | Get a list with its members  |
| POST   | `/api/contact-lists/{list_id}/members/` | Add a contact (also `/bulk`) |
| GET    | `/api/contacts/`                        | List contacts (`?search=`)   |

## Credentials

The loop only needs a `credential_id` (an `AWS_SES` credential) to pass to sends — you
don't fetch it. `GET /api/credentials/` lists metadata; `…/{id}/full` returns decrypted
data but requires JWT auth. Other `ServiceName` values exist (see openapi.json).
