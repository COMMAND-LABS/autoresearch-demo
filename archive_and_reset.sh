#!/usr/bin/env bash
#
# archive_and_reset.sh — Archive the current run's artifacts into
# archive/<experiment>/, then clear the working dir so a new run starts clean.
#
# A run leaves two artifacts: progress.tsv and iter_payloads/ (plus loop.log if you
# logged to one). loop_prompt.txt is COPIED — the archive records the config that
# produced the run, and you keep the file to edit for next time. loop_helpers.py is
# shared code and is left untouched.
#
# Usage:
#   ./archive_and_reset.sh        # prompts for confirmation
#   ./archive_and_reset.sh -y     # skip the prompt
#
set -euo pipefail
cd "$(dirname "$0")"

PROGRESS="progress.tsv"
ASSUME_YES="${1:-}"

# Gather what a run leaves behind.
shopt -s nullglob
EXISTING=()
for f in "$PROGRESS" progress-*.tsv loop.log; do
  [[ -e "$f" ]] && EXISTING+=("$f")
done
if [[ -d iter_payloads ]] && compgen -G 'iter_payloads/*' > /dev/null; then
  EXISTING+=("iter_payloads")
fi
shopt -u nullglob

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "No run artifacts found (progress.tsv / iter_payloads / loop.log) — nothing to archive."
  exit 0
fi

# Derive label + summary from progress.tsv (col: experiment, iteration, balanced_score).
read -r EXPERIMENT ITER BEST < <(python3 -c "
import csv, os
exp, it, best = 'run', 0, 0.0
if os.path.exists('$PROGRESS'):
    rows = list(csv.DictReader(open('$PROGRESS'), delimiter='\t'))
    if rows:
        exp = rows[-1].get('experiment') or exp
        it = rows[-1].get('iteration') or it
        try: best = max(float(r.get('balanced_score') or 0) for r in rows)
        except ValueError: pass
print(exp, it, round(float(best), 4))
")

DEST="archive/${EXPERIMENT}"
# Don't clobber a prior archive of the same experiment — suffix _2, _3, ...
if [[ -e "$DEST" ]]; then
  n=2
  while [[ -e "${DEST}_${n}" ]]; do n=$((n + 1)); done
  DEST="${DEST}_${n}"
fi

echo "About to archive run:"
echo "  experiment: $EXPERIMENT"
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
for f in "${EXISTING[@]}"; do
  mv -v "$f" "$DEST/"
done
# Copy the input config for reference; leave the original to edit for next run.
[[ -e loop_prompt.txt ]] && cp -v loop_prompt.txt "$DEST/"
rm -rf __pycache__

echo
echo "Archived to $DEST/:"
ls -1 "$DEST"
echo
echo "Working dir cleared. Edit loop_prompt.txt (new experiment name, params) and"
echo "start a fresh loop when ready."
