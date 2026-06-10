---
name: email-optimization
description: >
  Iterative email campaign optimization skill. Use this skill whenever the user wants to
  A/B test or optimize email campaigns, experiment with email subject lines or content,
  maximize email ratings or engagement, run an email experiment loop, tweak email templates
  to improve performance, or find the best-performing variation of an email. Works in
  combination with the kalygo-api skill — always load both when this skill is active.
---

# Email Optimization Skill

Orchestrates an iterative loop that sends an email campaign, waits for star-rating
responses, scores the variation, and tweaks the content toward the highest
`balanced_score`. Each iteration appends a row to `progress.tsv` so the run can be
inspected and resumed.

**Always load the `kalygo-api` skill alongside this one** — it has the endpoint
details and auth patterns. Use the helpers in `loop_helpers.py` for every API call
and the scoring math; do not re-implement them.

---

## Working-Directory Discipline (read this first)

This implementation is deliberately small. **Keep it that way.** A run writes
exactly **two** things — don't invent files or folders.

| Path                         | What                                               |
| ---------------------------- | -------------------------------------------------- |
| `progress.tsv`               | One row per iteration — the scoreboard (see below) |
| `iter_payloads/iter{N}.json` | The exact content sent in iteration N              |

That's the whole persistence model. Everything else (best score, best content,
plateau count) is **derived** from these two on the fly — there is no separate
state file.

**Rules:**

- **One folder for content: `iter_payloads/`.** Save each variant as
  `iter_payloads/iter{N}.json`. Never create parallel folders (`specs/`, `drafts/`,
  `variants/`, `notes/`) and never write `iterN_v2.json` — overwrite on retry.
- **Reuse `loop_helpers.py`.** Don't author new helper scripts at the root. A rare
  one-off goes under `.loop_scratch/` (gitignored), never the project root.
- **No stray reports** (`summary.md`, `report.json`, …). The run's output is the
  `@@ITER` stdout lines + the end-of-run report in chat; the durable record is
  `progress.tsv`.
- **Archiving is handled.** `./archive_and_reset.sh` moves `progress.tsv` and
  `iter_payloads/` into `archive/<experiment>/` and clears the working dir. Never
  hand-roll archive folders.

Before finishing, `ls` the tree; delete anything outside the two paths above.

---

## Configuration Parameters

| Parameter               | Default                           | Description                                                           |
| ----------------------- | --------------------------------- | --------------------------------------------------------------------- |
| `experiment`            | required                          | Short name for this run, e.g. `"product-launch-A"`. Labels every row. |
| `contact_list_id`       | required                          | Contact list to send to each iteration                                |
| `base_template_id`      | required                          | Immutable template; rendered per-iteration with `variables`           |
| `credential_id`         | required                          | Stored AWS_SES (or other) credential used to send                     |
| `wait_minutes`          | 60                                | How long to wait after sending before measuring ratings               |
| `max_iterations`        | 10                                | Hard cap on iterations                                                |
| `convergence_threshold` | 0.05                              | Min score improvement that counts as "better"                         |
| `patience`              | 3                                 | Consecutive non-improving iterations before stopping                  |
| `target_score`          | 4.0                               | Early-stop if `balanced_score` exceeds this                           |
| `what_to_vary`          | `["subject", "body_tone", "cta"]` | Aspects of the content to experiment with                             |

---

## Setup

1. **Confirm the config** (table above) — ask for required values, confirm defaults.
2. **Pre-flight:** load the base template via `get_template(base_template_id)` and note
   its declared `variables` (the tokens you'll supply — e.g. SUBJECT, TITLE,
   MAIN_CONTENT). **The template is immutable; never clone or mutate it.** Verify the
   contact list exists and note its size. Warn if it's tiny (< ~30): participation
   rate becomes coarse and one rater dominates — a plumbing test, not a real A/B.
3. **Start clean.** A new experiment must not inherit a previous one's files. If
   `progress.tsv` or `iter_payloads/` already hold data, run `./archive_and_reset.sh`
   first. Then write `progress.tsv` with the header row only, and create an empty
   `iter_payloads/`.
4. **Confirm and go.** Recap the setup in one short message; in autonomous mode,
   proceed without waiting.

---

## The Progress File (`progress.tsv`)

A tab-separated file, one row appended per iteration. It is the durable record of
the run — human-readable, greppable, and the input to archiving.

Columns (in order, tab-separated, **no tabs or newlines inside any field**):

```
iteration  experiment  campaign_id  balanced_score  avg_rating  num_ratings  send_count  participation_rate  status  what_changed
```

| Column               | Type   | Notes                                                    |
| -------------------- | ------ | -------------------------------------------------------- |
| `iteration`          | int    | 1-indexed                                                |
| `experiment`         | string | The run label                                            |
| `campaign_id`        | int    | Kalygo campaign created for this iteration               |
| `balanced_score`     | float  | `avg_rating × √(participation_rate)`. `0.0` on crash.    |
| `avg_rating`         | float  | Mean rating this iteration. `0.0` on crash.              |
| `num_ratings`        | int    | Ratings received. `0` on crash.                          |
| `send_count`         | int    | `summary["sent"]` from `execute_campaign`. `0` on crash. |
| `participation_rate` | float  | `num_ratings / send_count`, 3 dp. `0.0` on crash.        |
| `status`             | string | `keep`, `discard`, or `crash` (semantics below)          |
| `what_changed`       | string | Short prose describing the variant + why                 |

`status` semantics:

- `keep` — `balanced_score` beat the best so far by more than `convergence_threshold`.
  This variant becomes the reference for the next iteration.
- `discard` — no meaningful improvement. The next iteration derives its variant from
  the prior best, not from this one. Counts toward `patience`.
- `crash` — unusable (send error, validation failure, zero ratings). Doesn't advance
  the best; doesn't count toward `patience`.

Example:

```
iteration	experiment	campaign_id	balanced_score	avg_rating	num_ratings	send_count	participation_rate	status	what_changed
1	mar5-onboarding	17	1.83	3.7	12	50	0.24	keep	baseline (unchanged from base template)
2	mar5-onboarding	18	2.41	4.1	17	50	0.34	keep	shortened subject from 64 to 38 chars
3	mar5-onboarding	19	2.29	4.0	16	50	0.32	discard	added urgency word "today" to subject
4	mar5-onboarding	21	0.0	0.0	0	0	0.0	crash	send 422 — invalid placeholder in HTML
```

`awk -F'\t' '$9=="keep"' progress.tsv` gives just the iterations that advanced the run.

---

## The Loop

Track two things **in working memory** during a run (no state file):

- **`best_score`** — highest `balanced_score` so far (start `-inf`).
- **`best_values`** — the `variables` dict that produced it (start = baseline content).

Each iteration derives its variant **from `best_values`**, not the previous
iteration's. `discard`/`crash` revert cleanly by simply not updating `best_values`.

Repeat until convergence:

### Step 1 — Choose the variant values

You choose the `variables` dict to send. Iteration 1 = the baseline. Iteration N > 1
= derive from `best_values` with one or two changes informed by prior results.

What to vary (cycle / combine, guided by `what_to_vary`): **subject** (length, tone —
curiosity vs urgency vs benefit), **body copy** (`MAIN_CONTENT` — hook, value prop,
tone, length), **CTA**, **rating prompt** placement/framing, **topic angle**.

Think like an optimizer: big swings early, refinements once scores plateau, **never
more than 2 variables at once** (so you can attribute the change). **Simplicity beats
novelty** — removing clutter for equal-or-better scores is a `keep`.

Include only **campaign-scoped** content tokens, e.g.
`{ "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..." }`. Do **not** include
`RATING_BASE_URL` or contact tokens like `first_name` — those are system/contact-scoped
and resolved server-side per recipient.

**Persist the payload before sending:** write it to `iter_payloads/iter{N}.json`,
including at minimum the `variables` you'll send plus `iter` and `what_changed`:

```json
{
  "iter": 4,
  "what_changed": "added {{first_name}} to subject",
  "SUBJECT": "...",
  "TITLE": "...",
  "MAIN_CONTENT": "..."
}
```

### Step 2 — Create the campaign (grouping tag)

`create_campaign(name="{experiment}-iter-{N}", contact_list_id=..., description=...)`.
The campaign stores no template or content — it's just the tag that this iteration's
sends and ratings attribute to. Record the returned `campaign_id`.

### Step 3 — Send

Send the immutable base template rendered with this iteration's `variables` to the
whole list under this campaign:

```python
execute_campaign(campaign_id, base_template_id, variables, contact_list_id, credential_id)
```

It loops the not-yet-sent contacts (`GET …/unsent`), calls `POST /api/emails/send` per
contact, dedupes `(campaign_id, contact_id)`, and is **idempotent + resumable** — a
crashed run resumes by simply calling it again. Record `summary["sent"]` as the
participation denominator.

On **iteration 1 only**, first call with `dry_run=True` to surface template /
credential / missing-variable problems (a `422` lists unresolved variables) before any
recipient is touched; fix and re-dry-run until clean, then send for real.

### Step 4 — Wait

Wait `wait_minutes` for ratings. Say once that the iteration was sent and when
measurement will happen; don't re-narrate during the wait. To exit early, poll
`get_ratings_summary(campaign_id)` and stop when `total_ratings == send_count`.

### Step 5 — Measure & score

`get_ratings_summary(campaign_id)` → `{ total_ratings, average_rating, ... }`.
Use `total_ratings` as `num_ratings` and `average_rating` as `avg_rating`, then:

```
participation_rate = num_ratings / send_count
balanced_score     = avg_rating × √(participation_rate)
```

(Use `balanced_score(avg_rating, num_ratings, send_count)` from `loop_helpers.py`.)

### Step 6 — Record

Append one row to `progress.tsv`:

- `keep` if `balanced_score > best_score + convergence_threshold` → update `best_score`
  and `best_values`.
- `discard` otherwise → leave `best_*` unchanged.
- `crash` if the iteration was unusable → leave `best_*` unchanged.

(The `iter_payloads/iter{N}.json` file was already written in Step 1.)

### Step 7 — Check convergence

Stop when **any** is true:

- `balanced_score` exceeded `target_score` (write the row, then stop).
- The last `patience` iterations are all `discard` (no improvement beyond threshold).
  `crash` rows don't count.
- `max_iterations` reached.

When stopping, optionally set the iteration campaigns to `status: completed` and present
the final report. There is no template to revert — the base template was never touched.

---

## Resume

There is no state file to read. To resume an interrupted run, derive everything from
the two artifacts:

- **`best_score` / best iteration** → the highest-`balanced_score` row in `progress.tsv`.
- **`best_values`** → `iter_payloads/iter{that-iteration}.json`.
- **plateau count** → trailing rows whose `status` is not `keep`.
- **next iteration number** → last row's `iteration` + 1.

`execute_campaign` is itself resumable, so a crash mid-send just re-runs that iteration.

---

## Crash Handling

- **Send returned 4xx/5xx** — read the error. A fixable config issue (missing credential
  field, validation error) → fix and retry the same iteration without incrementing.
  A flaw in the variant (e.g. invalid HTML) → record `crash` and move on.
- **Zero ratings after wait** — record `crash`; note in `what_changed` that delivery may
  have failed, and check delivery before continuing.
- **Network/API timeout** — retry once; if it fails again, record `crash`.

After more than two consecutive `crash` rows, something systemic is wrong — stop and
surface it.

---

## Autonomous Mode

By default the loop pauses for confirmation between iterations. If the user asks for an
autonomous run ("just keep going", "don't ask"), drop the check-ins and run to
convergence / max iterations / repeated crashes, then write the final report. Watch for
**recipient fatigue** — at most one iteration per `wait_minutes` window to the same list;
real humans are receiving these.

---

## Reporting

After each iteration, EMIT a 3-line status block to stdout via an actual shell/echo
command (so it shows up in streamed output — do NOT merely narrate it). Each line MUST
begin with the literal marker `@@ITER`:

```
@@ITER [iter N/MAX] varied: <what changed vs. the current best, and why>
@@ITER sent <s>/<t> · waited <w>m · ratings <r> · avg <a>
@@ITER score <x> vs best <y> -> <new-best|keep|discard|converged|patience> (<reason>)
```

Don't re-print the whole table each iteration (`cat progress.tsv` if wanted). At the end
of the run, show: the full `progress.tsv` as a table; the best iteration and its score;
the winning `SUBJECT` + a summary of the `MAIN_CONTENT` approach; and key learnings (what
moved the score, what didn't, where to explore next).

---

## Edge Cases

- **Tiny contact list** (< ~30): coarse participation rate, idiosyncratic raters — note
  the caveat in the final report so the winner isn't over-interpreted.
- **No rating variance**: small/homogeneous list, or the ceiling is being hit — note it.
- **List fatigue**: watch for declining participation across iterations; consider longer
  `wait_minutes` or fewer iterations.
