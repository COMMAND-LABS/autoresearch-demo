#!/usr/bin/env bash
#
# archive_and_reset.sh — Archive the current autoresearch loop's artifacts into
# archive/<branch>/, then clear loop state so a new loop can begin cleanly.
#
# Generated artifacts (.loop_state.json, progress*.tsv, loop.log) are MOVED into
# the archive (clearing the working dir). loop_prompt.txt is COPIED (the archive
# records the config that produced the run; you keep the file to edit next time).
# .loop_helpers.py is shared code and is left untouched.
#
# Works whether or not a run is still "live": .loop_state.json exists only while
# a loop is in progress and is removed on completion, so a finished run leaves
# only progress.tsv behind. This script archives whenever ANY artifact is present
# and derives the branch label from progress.tsv when the state file is gone.
#
# Usage:
#   ./archive_and_reset.sh         # prompts for confirmation
#   ./archive_and_reset.sh -y      # skip the prompt
#
set -euo pipefail
cd "$(dirname "$0")"

STATE_FILE=".loop_state.json"
PROGRESS="progress.tsv"
ASSUME_YES="${1:-}"

# Gather everything a run can leave behind.
shopt -s nullglob
EXISTING=()
for f in "$STATE_FILE" "$PROGRESS" progress-*.tsv loop.log; do
  [[ -e "$f" ]] && EXISTING+=("$f")
done
# Per-iteration content payloads: archive the whole folder, but only if it holds
# something — an empty iter_payloads/ isn't an artifact worth moving.
if [[ -d iter_payloads ]] && compgen -G 'iter_payloads/*' > /dev/null; then
  EXISTING+=("iter_payloads")
fi
shopt -u nullglob

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "No loop artifacts found (.loop_state.json / progress.tsv / iter_payloads / loop.log) — nothing to archive."
  exit 0
fi

# Derive a label + summary: prefer the live state file, fall back to progress.tsv.
read -r BRANCH ITER BEST < <(python3 -c "
import json, os, csv
branch, it, best = 'unknown', 0, 0.0
if os.path.exists('$STATE_FILE'):
    s = json.load(open('$STATE_FILE'))
    branch = s.get('branch', branch)
    it = s.get('iteration', it)
    best = float(s.get('best_score', best) or 0)
elif os.path.exists('$PROGRESS'):
    rows = list(csv.DictReader(open('$PROGRESS'), delimiter='\t'))
    if rows:
        branch = rows[-1].get('branch') or branch
        it = rows[-1].get('iteration') or it
        try: best = max(float(r.get('balanced_score') or 0) for r in rows)
        except ValueError: pass
print(branch, it, round(float(best), 4))
")

DEST="archive/${BRANCH}"
# Don't clobber a prior archive of the same branch — suffix _2, _3, ...
if [[ -e "$DEST" ]]; then
  n=2
  while [[ -e "${DEST}_${n}" ]]; do n=$((n + 1)); done
  DEST="${DEST}_${n}"
fi

echo "About to archive autoresearch loop:"
echo "  branch:     $BRANCH"
echo "  iterations: $ITER"
echo "  best_score: $BEST"
echo "  artifacts:  ${EXISTING[*]}"
echo "  -> $DEST/"
echo
if [[ "$ASSUME_YES" != "-y" ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$DEST"

# Move every detected artifact (clears the working dir).
for f in "${EXISTING[@]}"; do
  mv -v "$f" "$DEST/"
done

# Copy the input config for reference; leave the original to edit for next run.
[[ -e loop_prompt.txt ]] && cp -v loop_prompt.txt "$DEST/"

# Drop the ephemeral bytecode cache.
rm -rf __pycache__

echo
echo "Archived to $DEST/:"
ls -1 "$DEST"
echo
echo "Loop state cleared. Edit loop_prompt.txt (new branch name, params) and"
echo "start a fresh loop when ready."