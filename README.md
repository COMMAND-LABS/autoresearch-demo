# TLDR

Herein lies an autoresearch implementation for optimizing email content based on "balanced_score" [avg_rating × √(participation_rate)]

## How to kick off the autoresearch loop

```sh
claude --dangerously-skip-permissions -p "$(cat loop_prompt.txt)" \
  --output-format stream-json --verbose \
  | jq -r --unbuffered '
    if .type=="assistant" then
      (.message.content[]? |
        if .type=="text" then .text
        elif .type=="tool_use" then
          "  · " + .name + (
            if .input.description then ": " + .input.description
            elif .input.file_path then ": " + .input.file_path
            elif .input.skill then ": " + .input.skill
            elif .input.query then ": " + .input.query
            else "" end)
        else empty end)
    elif .type=="user" then
      (.message.content[]? | select(.type=="tool_result")
        | (.content | if type=="array" then (map(.text? // "") | join("\n")) else (. // "") end)
        | split("\n")[] | select(startswith("@@ITER")) | sub("^@@ITER ?"; "")
        | if startswith("[iter") then "\n──────── iteration ────────\n" + . else . end)
    elif .type=="result" then
      "=== done: \(.usage.output_tokens) out tokens, $\(.total_cost_usd) ==="
    else empty end'
```

## Reference links

- https://code.claude.com/docs/en/devcontainer#how-dev-containers-work-with-your-editor
- https://github.com/anthropics/claude-code/tree/main/.devcontainer

## Glossary of terms

`participation_rate`: num_ratings / send_count

`balanced_score`: avg_rating × √(participation_rate) <!-- a "good" email is one that's both rated highly and rated by many -->

`base_template_id`: 6 — the email template each iteration uses

`what_to_vary`: which aspects the "optimizer" is allowed to change (subject line, body copy, CTA, rating prompt, topic angle). "everything" gives it full latitude. Why? it scopes the search space. Narrow it (e.g. subject only) when you want to isolate one lever; everything lets it explore broadly but makes it harder to attribute which change moved the score.

`contact_list_id`: 3 — the recipient list every iteration sends to. Why? this audience produces the ratings, and its size determines whether the score means anything. With 3 contacts, participation jumps in coarse 33% steps and one person's mood dominates — the score is noisy. This is a plumbing test, not a real A/B.

`credential_id`: 30 — the stored AWS SES credential used to actually deliver the mail. Why? it's the sending identity/auth; without it nothing leaves the building.

`branch`: ar-exp-6_9_26\_\_1_20pm — a label for the current autoresearch experiment. Why? it groups one experiment's artifacts so runs can be told apart, resumed, and archived.

`wait_minutes`: how long to wait for feedback after running the system Why? recipients need time to open and tap a star; measure too early and you record zeros. At 1 minute, humans can't respond in time — bump to 5–10+ for real signal (1 is fine only to test the pipeline).

`max_iterations`: 10 — a hard cap on cycles. Why? guarantees termination and bounds cost, runtime, and recipient fatigue, regardless of the other rules.

`target_score`: 4.7 — stop early if balanced_score exceeds this ("good enough, ship it"). Why? a success threshold so it doesn't keep iterating past a clearly-great result. Note: 4.7 is effectively unreachable — max score is 5 × √(participation), and on a 3-person list with ~1 rater the ceiling is 5 × √(1/3) ≈ 2.9. So this run will never stop on target; it'll stop via patience or max_iterations.

`convergence_threshold`: 0.05 — the minimum balanced_score improvement that counts as "better." An iteration is keep only if it beats the best-so-far by more than 0.05; otherwise discard. Why? it filters real gains from noise — without it, a meaningless +0.001 wiggle would look like progress and the loop would never settle.

`patience`: 3 — stop after this many consecutive non-improving (discard) iterations. Why? the plateau detector. Once 3 rounds in a row fail to beat the best by the threshold, further tweaking is probably not helping.
