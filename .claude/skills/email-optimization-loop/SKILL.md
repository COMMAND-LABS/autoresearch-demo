---
name: email-optimization-loop
description: >
  Iterative email campaign optimization skill. Use this skill whenever the user wants to
  A/B test or optimize email campaigns, experiment with email subject lines or content,
  maximize email ratings or engagement, run an email experiment loop, tweak email templates
  to improve performance, or find the best-performing variation of an email. Works in
  combination with the kalygo-api skill — always load both when this skill is active.
---

# Email Optimization Loop Skill

This skill orchestrates an iterative experiment loop that sends email campaigns,
waits for star-rating responses, scores each variation, and tweaks the template
toward the highest possible balanced score. Each iteration's outcome is recorded
to a `progress.tsv` file so the run can be paused, resumed, and inspected at any
time.

**Always load the `kalygo-api` skill alongside this one** — it provides all endpoint
details and auth patterns needed to execute API calls.

For data structures (IterationRecord, progress.tsv schema, scoring formula, convergence
criteria), see `references/experiment-log-schema.md`.

---

## Working-Directory Discipline (read this first)

This implementation is deliberately small and clean. **Keep it that way.** A run
produces a *fixed, known* set of artifacts — do not invent new files or folders.
The most common failure mode here is the agent scattering scratch files and
parallel folders (`specs/`, `drafts/`, `variants/`, ad-hoc `*.py`) around the
project. Don't.

**The only paths a run may write:**

| Path                          | What                                                          | When                          |
| ----------------------------- | ------------------------------------------------------------ | ----------------------------- |
| `progress.tsv`                | One TSV row per iteration — the durable log                  | appended each iteration       |
| `iter_payloads/iter{N}.json`  | The exact content payload chosen for iteration N             | written in Step 1, pre-send   |
| `.loop_state.json`            | Optional resumable state (`best_score`, `best_values`, iter) | updated each iteration         |
| `loop.log`                    | Optional plain-text run log                                  | as needed                     |
| `.loop_scratch/`              | The **only** home for any throwaway helper you must write    | rare                          |

**Rules:**

- **One folder for per-iteration content: `iter_payloads/`.** Every iteration's
  variant is saved as `iter_payloads/iter{N}.json` — and nothing else. Do NOT
  create parallel folders such as `specs/`, `drafts/`, `variants/`, `content/`,
  or `notes/`. If `iter_payloads/` does not exist, create that one directory and
  use it for every iteration.
- **One file per iteration; overwrite on retry.** Re-running iteration N (e.g.
  after a `crash`) overwrites `iter_payloads/iter{N}.json`. Never write
  `iter3_v2.json`, `iter3_retry.json`, or similar.
- **Reuse `loop_helpers.py`.** All API calls and scoring already live there. Do
  not author new helper scripts in the project root. If you truly need a one-off,
  put it under `.loop_scratch/` (gitignored) — never at the root.
- **No stray reports.** Don't drop `summary.md`, `report.json`, `analysis.txt`,
  etc. The end-of-run report goes to the chat and the `@@ITER` stdout lines; the
  durable record is `progress.tsv`.
- **Archiving is handled — don't hand-roll it.** `./archive_and_reset.sh` moves a
  run's artifacts (including `iter_payloads/`) into `archive/<branch>/` and clears
  the working dir so the next experiment starts clean. Never create your own
  `archive*/` or dated backup folders.

Before you finish a run, glance at the working tree (`git status` / `ls`). If you
created anything outside the table above, delete it — it is clutter.

---

## Configuration Parameters

Before starting a loop, confirm these with the user:

| Parameter               | Default                           | Description                                                           |
| ----------------------- | --------------------------------- | --------------------------------------------------------------------- |
| `experiment`            | required                          | Short name for this research experiment, e.g. `"product-launch-A"`    |
| `contact_list_id`       | required                          | ID of the contact list to send to each iteration                      |
| `base_template_id`      | required                          | ID of the immutable template; rendered per-iteration with `variables` |
| `credential_id`         | required                          | ID of the stored AWS_SES (or other email) credential used to send     |
| `wait_minutes`          | 60                                | How long to wait after sending before measuring ratings               |
| `max_iterations`        | 10                                | Hard cap on iterations                                                |
| `convergence_threshold` | 0.05                              | Min score improvement to keep going                                   |
| `patience`              | 3                                 | How many consecutive non-improving iterations before stopping         |
| `target_score`          | 4.0                               | Optional early-stop if balanced_score exceeds this                    |
| `what_to_vary`          | `["subject", "body_tone", "cta"]` | Aspects of the template to experiment with                            |

---

## Setup

Before entering the iteration loop:

1. **Agree on the experiment tag.** Propose one based on today's date or the campaign's
   purpose (e.g. `mar5-onboarding`). The experiment name is used as a label in
   `progress.tsv` and in campaign names — it does not need to map to a git experiment.
2. **Resolve config parameters** (above table) — ask the user for any required
   values and confirm defaults for the rest.
3. **Pre-flight checks** — see `### Pre-flight` below: fetch base template (note its
   variables), verify contact list. The template is never cloned or mutated.
4. **Initialize the run's working files.** Write `progress.tsv` with the header row
   only (the baseline iteration is appended after iteration 1 completes; see
   `references/experiment-log-schema.md` for the column schema), and ensure an
   **empty `iter_payloads/`** directory exists for per-iteration content. If
   `progress.tsv` or `iter_payloads/` already hold files from a previous run, the
   experiment must start clean — run `./archive_and_reset.sh` first (it moves the
   old artifacts into `archive/<branch>/`) rather than mixing runs or spawning a
   new folder.
5. **Confirm and go.** Recap the setup to the user in one short message and wait
   for confirmation before sending the first iteration.

---

## The Progress File (`progress.tsv`)

A tab-separated file appended to once per iteration. It is the durable record of the
run — IterationRecord lives in conversation memory, but `progress.tsv` survives
restarts and is human-readable.

Columns (in order, tab-separated, no commas in any field):

```
iteration  experiment  campaign_id  balanced_score  avg_rating  num_ratings  send_count  participation_rate  status  what_changed
```

`status` values:

- `keep` — score improved over best so far; this becomes the new reference point
- `discard` — score did not improve; on the next iteration, derive the new variant
  from the best-so-far template content, not from this one
- `crash` — send failed, template was invalid, or measurement failed; next
  iteration treats this row as if it never happened (no advance, no revert)

The file is **untracked by git**. It belongs to a single run.

For the full schema and an example, see `references/experiment-log-schema.md`.

---

## The Loop

### Pre-flight

1. Load the base template via `GET /api/email-templates/{base_template_id}` and note its
   declared `variables` — the tokens you'll supply per iteration (e.g. SUBJECT, TITLE,
   MAIN_CONTENT). **The template is immutable; you never clone or mutate it.** Content
   rides in as `variables` on each send.
2. Verify the contact list exists and has members via `GET /api/contact-lists/{list_id}`.
3. Note the contact-list size — small lists (< ~30 contacts) cannot produce useful
   signal because participation rate has too few discrete values. Warn the user
   and ask them to confirm before proceeding.

---

### Iteration Loop

Maintain two pieces of state across iterations:

- **`best_score`** — highest `balanced_score` observed so far (start at `-inf`)
- **`best_values`** — the `variables` dict (e.g. `{SUBJECT, TITLE, MAIN_CONTENT}`) from
  the iteration that produced `best_score` (start as the baseline content values)

Each iteration derives its variant **from `best_values`**, not from the previous
iteration's values. This is how `discard` reverts cleanly — by simply not updating
`best_values`, the next iteration rebuilds its variant from the prior best content.
The base template is never touched; only the values you send change.

Repeat until convergence:

#### Step 1 — Choose the variant values

You do **not** touch the template. You choose the `variables` dict to send this iteration.

On iteration 1: use the baseline content values.
On iteration N > 1: derive the new values from `best_values` by applying one or two
changes informed by what previous iterations revealed.

**What to vary (cycle through or combine):**

- **Subject line** (the `SUBJECT` value): Try different lengths, tones (curiosity vs. urgency vs. benefit-led), personalization tokens like `{{first_name}}`.
- **Body copy** (the `MAIN_CONTENT` value): Change the opening hook, value proposition, emotional tone, length.
- **CTA**: Wording, placement, button vs. text link.
- **Rating prompt**: How you ask them to rate — placement above vs. below the fold, framing.
- **Topic angle**: What aspect of the topic is emphasized (features vs. outcomes vs. story).

When choosing values, think like an iterative optimizer:

- Start broad (big changes) in early iterations.
- Narrow to refinements once scores plateau.
- Never change more than 2 variables at once — so you can attribute score changes.
- **Simplicity beats novelty.** A change that adds clutter for a marginal score
  gain is not worth keeping. Removing words or fields and getting equal-or-better
  scores is a win — record it as `keep`.

The result is the `variables` dict you'll pass to send, e.g.:

```
{ "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..." }
```

Only include **campaign-scoped** content tokens here. Do **not** put `RATING_BASE_URL`
or personalization tokens (`first_name`) in `variables` — those are system/contact-scoped
and resolved server-side per recipient at send time.

**Persist the payload before sending.** Write this iteration's chosen content to
`iter_payloads/iter{N}.json` (the one canonical folder — see Working-Directory
Discipline). At minimum include the `variables` you will send plus `iter` and
`what_changed`; you may also store the structured building blocks you composed
`MAIN_CONTENT` from. This is the single source of truth for "what did iteration N
actually send" — don't duplicate it into any other folder.

```json
{
  "iter": 4,
  "what_changed": "added {{first_name}} token to subject",
  "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..."
}
```

#### Step 2 — Create the campaign (grouping tag)

```
POST /api/email-campaigns/
{
  "name": "{experiment}-iter-{N}",
  "description": "Iteration {N} of email optimization loop for experiment {experiment}",
  "contact_list_id": {contact_list_id}
}
```

The campaign stores **no template or content** — it is only the tag that this
iteration's sends and ratings attribute to. Record the returned `campaign_id`.

#### Step 3 — Send

Send the **immutable base template** rendered with this iteration's `variables` to the
whole list, under this campaign. Use the `execute_campaign` helper — it loops the
contacts, calls `POST /api/emails/send` per contact, and is idempotent + resumable:

```python
execute_campaign(campaign_id, base_template_id, variables, contact_list_id, credential_id)
```

which fans out:

```
POST /api/emails/send
{ "campaign_id": {campaign_id}, "template_id": {base_template_id},
  "variables": {SUBJECT, TITLE, MAIN_CONTENT}, "recipient": {"contact_id": N},
  "credential_id": {credential_id}, "dry_run": false }
```

On **iteration 1 only**, first run it with `dry_run=True` to surface template / credential
/ missing-variable problems before any recipient is touched. The send validates required
variables and returns `422` listing any that are unresolved — fix and re-dry-run until
clean, then send for real.

Each send writes a row to the `email_events` ledger keyed by `(campaign_id, contact_id)`,
and the backend dedupes that pair. So a crashed run resumes by simply calling
`execute_campaign` again — only not-yet-sent contacts (per `GET /api/email-campaigns/
{campaign_id}/unsent`) are attempted, with no double-mailing. Record the number actually
sent (`summary["sent"]`) as the participation-rate denominator and `timestamp_sent = now()`.

#### Step 4 — Wait

Wait `wait_minutes` for recipients to rate. Tell the user once that the iteration has
been sent and roughly when measurement will occur — do not re-narrate during the wait.

If you want to exit the wait early when all recipients have rated, poll
`GET /api/email-campaigns/{campaign_id}/ratings/summary` periodically and break when
`total_ratings == send_count`.

#### Step 5 — Measure

Use the campaign-ratings endpoint, NOT `email-events`. (Ratings written by the
`/t/r/{tracking_id}/{rating}` tracker land in the `email_campaign_ratings` table,
not in `email_events` as `click` events.)

```
GET /api/email-campaigns/{campaign_id}/ratings/summary
→ { campaign_id, total_ratings, average_rating, distribution, by_template }

GET /api/email-campaigns/{campaign_id}/ratings?limit=500
→ list of RatingResponse rows (rating, contact_id, tracking_id, created_at)
```

Use `total_ratings` as `num_ratings` and `average_rating` as `avg_rating`.

**Calculate scores:**

```
participation_rate = num_ratings / send_count
balanced_score     = avg_rating × √(participation_rate)
```

#### Step 6 — Record & Reflect

Build an `IterationRecord` (in-memory; see `references/experiment-log-schema.md`)
with the scores, template snapshot, what changed, hypothesis, observed result, and
your interpretation.

Then **append one row to `progress.tsv`** with:

- `status = keep` if `balanced_score > best_score + convergence_threshold`
- `status = discard` otherwise (no meaningful improvement)
- `status = crash` if the iteration was unusable (see Crash Handling)

If `status = keep`: update `best_score` and `best_values` for the next iteration.
If `status = discard` or `status = crash`: leave `best_*` unchanged. The next
iteration's Step 1 will derive its new variant from the prior best values.

#### Step 7 — Check Convergence

Stop the loop when **any** of these is true:

- `balanced_score` exceeded `target_score` (write the row, then stop)
- `patience` consecutive non-improving iterations recorded in `progress.tsv`
- `max_iterations` reached

When stopping: record `best_values` in the final report as the winning content, set the
iteration campaigns to `status: completed`, and present the final report (see Reporting).
There is no template to revert — the base template was never modified.

---

## Crash Handling

If an iteration fails partway through, decide whether to retry or skip:

- **Send call returned 4xx/5xx** — read the error. If it's a fixable config issue
  (missing credential field, malformed template, validation error), surface it to
  the user, fix it, and retry the same iteration without incrementing the iteration
  counter. If it's a fundamental flaw in the variant (e.g. body copy made the
  template invalid HTML), record `status = crash` and move on.
- **Zero ratings after wait** — record `status = crash` (or `discard` with a 0 score
  if you prefer). Note in `what_changed` that delivery may have failed; check
  bounce/delivery stats before continuing the loop.
- **Network or API timeout** — retry once. If it fails again, record `status = crash`
  and proceed.

After more than two consecutive crash rows, pause and surface the situation to the
user — something systemic is wrong.

---

## Autonomous Mode (optional)

By default, the loop pauses for user confirmation between iterations or when it
would otherwise stop. If the user explicitly asks for an autonomous run ("just keep
going while I'm asleep", "don't ask, just iterate"), drop those check-ins:

- Do not pause to ask "should I keep going?" between iterations.
- Continue until convergence, max iterations, or repeated crashes — then write the
  final report.
- Watch out for **recipient fatigue**: don't send more than one iteration per
  `wait_minutes` window to the same contact list, and consider capping at ~1
  iteration/hour against any human list. ML-style "100 experiments overnight" does
  not apply here — real recipients are on the receiving end.

---

## Reporting

After each iteration, EMIT a 3-line status block to stdout via an actual shell/echo
command (so it appears in streamed/piped output — do NOT merely narrate it in your
reply text, and do NOT collapse it to a single line). Each of the three lines MUST
begin with the literal marker `@@ITER`:

```
@@ITER [iter N/MAX] varied: <what changed vs. the current best, and why>
@@ITER sent <s>/<t> · waited <w>m · ratings <r> · avg <a>
@@ITER score <x> vs best <y> -> <new-best|keep|discard|converged|patience> (<reason>)
```

The `@@ITER` marker is what console filters grep for, so include it verbatim at the
start of each line. Do NOT re-print the full progress table every iteration; users
who want it can `cat progress.tsv`.

At the end of the run, show:

- The full `progress.tsv` rendered as a table
- Best iteration and its score
- The winning `SUBJECT` value and a short summary of the `MAIN_CONTENT` approach
- Key learnings distilled across all iterations (what kinds of changes moved the
  score, what didn't, where the next round of experimentation should focus)

---

## Edge Cases

- **Tiny contact list** (< ~30 contacts): the formula loses discriminating power
  because participation rate becomes coarse and individual rater idiosyncrasies
  dominate. Warn the user during Setup; if they proceed, note this caveat in the
  final report so they don't over-interpret the winning variant.
- **All same rating (no variance)**: The list may be small or homogeneous. Note in
  insights and consider that the ceiling is being hit, not improvement.
- **Contact list fatigue**: If the same contacts are receiving many iterations, they
  may stop rating. Watch for declining participation and consider longer
  `wait_minutes` or a smaller `max_iterations`.
- **`progress.tsv` already exists**: If a file with the same path is present at
  Setup time, ask the user whether to resume (read it, restore `best_*` from the
  highest-scoring `keep` row, continue numbering from the last iteration) or start
  fresh (rename or delete the existing file). Never silently overwrite.

---

## Example First Prompt

When the user says "start the optimization loop", ask for any missing config parameters,
then begin with:

> "Starting email optimization loop — experiment: `{experiment}`, contact list: {N} contacts,
> wait time: {wait_minutes} min, max iterations: {max_iterations}.
> Initialized `progress.tsv`. Iteration 1 will send the baseline template unchanged
> to establish a reference score."
