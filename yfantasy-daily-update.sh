#!/usr/bin/env bash
#
# yfantasy-daily-update.sh — daily pull -> collect -> commit -> push.
# Run by launchd (com.truyen.yfantasy.dailyupdate) every day at 16:00.
#
# Each step below is checked for success before the next one runs; the
# script stops (non-zero exit) at the first failure instead of chaining
# with `&&`, so the failing step is unambiguous in the log.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to ${SCRIPT_DIR}" >&2; exit 1; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== yfantasy daily update starting ==="

log "STEP 1: git pull"
if ! git pull; then
  echo "ERROR: git pull failed" >&2
  exit 1
fi

log "STEP 2: ./yfantasy-collect.sh"
if ! ./yfantasy-collect.sh; then
  echo "ERROR: yfantasy-collect.sh failed" >&2
  exit 1
fi

log "STEP 3: git add yfantasy.json"
if ! git add yfantasy.json; then
  echo "ERROR: git add failed" >&2
  exit 1
fi

if git diff --cached --quiet; then
  log "No changes to commit; skipping commit and push."
  log "=== yfantasy daily update finished (nothing to push) ==="
  exit 0
fi

log "STEP 4: git commit"
if ! git commit -m "Update yfantasy"; then
  echo "ERROR: git commit failed" >&2
  exit 1
fi

log "STEP 5: git push"
if ! git push; then
  echo "ERROR: git push failed" >&2
  exit 1
fi

log "=== yfantasy daily update finished successfully ==="
