# Experiment Log Schema

Each iteration of the email optimization loop produces two records:

- An **`IterationRecord`** — rich JSON kept in conversation memory, used for
  reasoning across iterations.
- A **row in `progress.tsv`** — compact tab-separated record persisted to disk.
  This is the durable log of the run.

---

## `progress.tsv`

A tab-separated values file appended to once per iteration. Lives in the working
directory of the experiment run. **Do not commit it to git** — it belongs to a
single run.

### Columns (in order)

```
iteration  branch  campaign_id  balanced_score  avg_rating  num_ratings  send_count  participation_rate  status  what_changed
```

| Column               | Type    | Notes                                                                |
| -------------------- | ------- | -------------------------------------------------------------------- |
| `iteration`          | int     | 1-indexed                                                            |
| `branch`             | string  | Run tag (e.g. `mar5-onboarding`)                                     |
| `campaign_id`        | int     | The Kalygo campaign id created for this iteration                    |
| `balanced_score`     | float   | `avg_rating × √(participation_rate)`. Use `0.000000` on crash.       |
| `avg_rating`         | float   | Mean of all ratings received this iteration. `0.0` on crash.         |
| `num_ratings`        | int     | Distinct rated contacts. `0` on crash.                               |
| `send_count`         | int     | `summary["sent"]` from `execute_campaign`. `0` on crash.             |
| `participation_rate` | float   | `num_ratings / send_count`, rounded to .001. `0.000` on crash.       |
| `status`             | string  | `keep`, `discard`, or `crash`                                        |
| `what_changed`       | string  | Short prose describing the variant. Tabs and newlines disallowed.    |

### `status` semantics

- `keep`     — the iteration's `balanced_score` improved over `best_score` by more
               than `convergence_threshold`. The new variant becomes the reference
               for subsequent iterations (`best_values` is updated).
- `discard`  — score did not improve meaningfully. Next iteration derives its
               variant from the prior `best_values`, not from this one. Counts
               toward the `patience` budget.
- `crash`    — iteration was unusable (send error, validation failure, zero
               ratings, etc.). Does not advance `best_values`; does not count
               toward `patience` (it never produced a comparable signal).

### Example

```
iteration	branch	campaign_id	balanced_score	avg_rating	num_ratings	send_count	participation_rate	status	what_changed
1	mar5-onboarding	17	1.830000	3.7	12	50	0.240	keep	baseline (unchanged from base template)
2	mar5-onboarding	18	2.410000	4.1	17	50	0.340	keep	shortened subject from 64 to 38 chars
3	mar5-onboarding	19	2.290000	4.0	16	50	0.320	discard	added urgency word "today" to subject
4	mar5-onboarding	20	2.890000	4.3	22	50	0.450	keep	added {{first_name}} token to subject
5	mar5-onboarding	21	0.000000	0.0	0	0	0.000	crash	send call 422 — invalid {{cta_url}} placeholder in HTML
6	mar5-onboarding	22	2.910000	4.3	23	50	0.460	keep	moved star ratings above the fold
```

Reading the file back: a simple `awk -F'\t' '$9=="keep" { print }' progress.tsv`
gives you only the iterations that advanced the run.

---

## `IterationRecord` (in-memory)

Held in conversation memory only. Captures reasoning that doesn't fit a TSV row.

```json
{
  "iteration": 1,
  "branch": "mar5-onboarding",
  "campaign_id": 17,
  "campaign_name": "mar5-onboarding-iter-1",
  "variables": {
    "SUBJECT": "...",
    "TITLE": "...",
    "MAIN_CONTENT": "..."
  },
  "what_changed": "Initial baseline — no changes.",
  "hypothesis": "Concise, benefit-led subject lines improve open and rating rates.",
  "send_count": 50,
  "rating_events": [
    { "contact_id": 1, "rating": 4, "timestamp": "2026-04-29T10:00:00Z" },
    { "contact_id": 2, "rating": 5, "timestamp": "2026-04-29T10:15:00Z" }
  ],
  "num_ratings": 12,
  "avg_rating": 4.2,
  "participation_rate": 0.24,
  "balanced_score": 2.06,
  "status": "keep",
  "insights": "Short subject performed better than expected. CTA button placement may matter.",
  "decision": "Increase emotional tone in body copy next iteration.",
  "timestamp_sent": "2026-04-29T09:00:00Z",
  "timestamp_measured": "2026-04-29T10:30:00Z"
}
```

---

## Balanced Score Formula

```
participation_rate = num_ratings / send_count
balanced_score     = avg_rating × √(participation_rate)
```

Range: 0–5 (theoretical max: 5.0 at 100% participation, all 5-star ratings).

**Examples:**

- 50 sent, 12 rated (24%), avg 4.2 → score = 4.2 × √0.24 = **2.06**
- 50 sent, 40 rated (80%), avg 3.8 → score = 3.8 × √0.80 = **3.39** ← wins

The `default target_score` is 4.0 because hitting 5.0 requires unanimous 5★ ratings
at 100% participation — essentially unreachable in honest measurement on any
non-trivial list. 4.0 corresponds to a clearly-good outcome (e.g. avg 4.5 at ~80%
participation).

---

## Convergence Criteria

Stop the loop when **any** of these is true:

- `balanced_score` exceeds `target_score` (default 4.0)
- The most recent `patience` iterations (default 3) all have `status = discard` —
  meaning none of them improved over `best_score` by more than
  `convergence_threshold` (default 0.05). `crash` rows do not count toward
  `patience`.
- `max_iterations` reached (default 10)

---

## Run Summary (final report)

When the loop ends, build a single object summarizing the run for the user:

```json
{
  "branch": "mar5-onboarding",
  "contact_list_id": 7,
  "base_template_id": 42,
  "wait_minutes": 60,
  "convergence_threshold": 0.05,
  "patience": 3,
  "target_score": 4.0,
  "max_iterations": 10,
  "started_at": "2026-04-29T09:00:00Z",
  "ended_at": "2026-04-29T15:30:00Z",
  "stopped_because": "target_score_exceeded",
  "best_iteration": 4,
  "best_score": 3.71,
  "best_values": { "SUBJECT": "...", "TITLE": "...", "MAIN_CONTENT": "..." },
  "iterations_run": 6,
  "iterations_kept": 3,
  "iterations_discarded": 2,
  "iterations_crashed": 1,
  "key_learnings": [
    "Personalization tokens lifted participation by ~10pp.",
    "Urgency framing in subject hurt avg_rating.",
    "Star placement above the fold helped participation."
  ]
}
```
