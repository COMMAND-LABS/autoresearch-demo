# TASK

Run an autoresearch loop in order to optimize a fun haiku delivered to an online audience via email.

The metric to optimize is the "balanced_score"...

participation_rate = num_ratings / send_count
balanced_score = avg_rating × √(participation_rate)

## AUTORESEARCH PARAMETERS

experiment_name: ar-exp-6_10_26\_\_1_36pm
contact_list_id: 3
email_template_id: 6
credential_id: 30
wait_minutes_for_feedback: 1
max_iterations: 7
convergence_threshold: 0.05
patience: 3
target_score: 4.5
what_to_vary: SUBJECT, TITLE, MAIN_CONTENT

## ADDITIONAL REQUIREMENTS

- Run fully autonomously.
- Do not call AskUserQuestion or pause for confirmation — choose sensible defaults and proceed through all iterations on your own.
- Only stop early if something is genuinely broken (e.g. the API is unreachable or sends fail)
- Ensure the MAIN_CONTENT is beautifully formatted for email inbox rendering
- Keep the styling of the MAIN_CONTENT straightforward so it renders as intended according to html email best practices
- Each experiment should start from scratch and not be influenced by past experiments
- Keep the project tree clean. A run writes only two things: `progress.tsv` (one row per iteration) and `iter_payloads/iter{N}.json` (the content sent). There is no separate state file — best score and best content are derived from those two. Do NOT create extra folders (e.g. `specs/`, `drafts/`) or new helper scripts at the root — reuse `ar_helpers.py`; put any rare throwaway scratch under `.loop_scratch/`.

## PROGRESS REPORTING

At the END of every iteration, EMIT a status block to stdout by
running an actual shell/echo command (do NOT merely narrate it in your reply — it
must be printed by a tool call so it shows up in the streamed tool output). Print
EXACTLY three lines, each line beginning with the literal marker `@@ITER`:
@@ITER [iter N/MAX] varied: <what changed vs. the current best, and why>
@@ITER sent <s>/<t> · waited <w>m · ratings <r> · avg <a>
@@ITER score <x> vs best <y> -> <new-best|keep|discard|converged|patience> (<reason>)
This is IN ADDITION to the one structured row you append to progress.tsv (don't drop
that). The `@@ITER` marker is what the console filter greps for, so include it
verbatim at the start of each of the three lines.

## PREVIEW OF CONFIG OF ASSOCIATED EMAIL TEMPLATE

{
"account_id": 1,
"name": "RATE_YOUR_EXPERIENCE",
"slug": "rate-your-experience",
"description": "Rate your experience email with interactive star rating",
"subject_template": "{{ SUBJECT }}",
"variables": [
{
"name": "SUBJECT",
"label": "Email subject",
"default": "",
"required": true
},
{
"name": "TITLE",
"label": "Headline text",
"default": "",
"required": true
},
{
"name": "MAIN_CONTENT",
"label": "Main body copy",
"default": "",
"required": true
},
{
"name": "RATING_BASE_URL",
"label": "Base URL for star rating links (e.g. https://api.example.com/t/r/<tracking_id>)",
"default": "https://api.kalygo.io/t/r/",
"required": true
}
],
"id": 6,
"created_at": "2026-04-29T03:33:11.175110+00:00",
"updated_at": "2026-04-29T03:33:11.175110+00:00"
}
