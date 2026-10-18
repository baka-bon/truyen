#!/usr/bin/env bash
#
# yfantasy-collect.sh — walk a range of video IDs through yfantasy-flow.sh
# and collect the resulting video session objects into yfantasy.json, then
# re-check the audio languages of the videos collected on earlier runs.
#
# Usage: ./yfantasy-collect.sh [START_ID]
#
# Starting video ID is chosen as:
#   1. START_ID, if given as an argument.
#   2. Otherwise, if yfantasy.json already exists: one past the highest
#      videoId found in it (i.e. resume where the last run left off).
#   3. Otherwise: 10000.
#
# For each video ID from the starting point up to END_ID (inclusive) this
# calls
#   ./yfantasy-flow.sh <ID>
# and expects yfantasy-flow.sh to be in quiet mode (VERBOSE=0), so its only
# stdout output is the one-line session JSON object, already stripped of
# segment playback URLs and asset keys.
#
# As soon as a call fails (yfantasy-flow.sh exits non-zero — e.g. a non-2xx
# HTTP status at any step, such as VIDEO_NOT_FOUND once the ID range runs
# past the last real video) the loop stops immediately. Everything collected
# up to that point is still written out.
#
# Audio check: the site sometimes adds audio languages to existing videos.
# After the loop, every video already in yfantasy.json (and not just fetched
# by the loop) is looked up in the public feed
#   GET /api/videos/feed?limit=1&videoId=<ID>
# which needs no guest account and returns the video's publicSegment — the
# same segment_0 stored as currentSegment. If its audioLanguages or
# publishedAudioVariant differ from the stored ones, the video is re-fetched
# through yfantasy-flow.sh so the
# unlocked hidden segments' audio fields are refreshed too, and the fresh
# object replaces the stored one. A video whose lookup or re-fetch fails keeps
# its stored object (with a warning) and does not stop the run.
#
# On exit, JSON objects collected THIS run (new and re-fetched) are written to
# yfantasy.json, in reversed order (highest videoId first):
#   - Started via rule 1 (explicit argument) or rule 2 (resumed from an
#     existing file): this run's results are MERGED into whatever was
#     already in yfantasy.json (deduped by videoId), so earlier progress is
#     preserved.
#   - Started via rule 3 (fell back to 10000, because no file existed yet):
#     yfantasy.json is written fresh from just this run's results — there is
#     nothing to merge with (or audio-check) on a from-scratch start.
#
# Requires: bash, curl, jq
#
set -uo pipefail   # no -e: each yfantasy-flow.sh call's exit status is
                    # inspected explicitly so the loop can stop cleanly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_SCRIPT="${SCRIPT_DIR}/yfantasy-flow.sh"
OUTPUT_FILE="${SCRIPT_DIR}/yfantasy.json"

END_ID=10100

FEED_URL="https://yfantasy.me/api/videos/feed"

if [[ ! -x "$FLOW_SCRIPT" ]]; then
  echo "ERROR: ${FLOW_SCRIPT} not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found on PATH" >&2
  exit 1
fi

# Resolve the starting ID (see the three rules in the header comment above)
# and whether this run's results should be merged into the existing
# yfantasy.json (rules 1 and 2) or written fresh (rule 3).
MERGE_MODE=false
if [[ $# -ge 1 ]]; then
  if [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: START_ID argument must be a non-negative integer, got: $1" >&2
    exit 1
  fi
  START_ID="$1"
  MERGE_MODE=true
  echo "Starting from argument: ${START_ID} (will merge into existing ${OUTPUT_FILE}, if any)" >&2
elif [[ -f "$OUTPUT_FILE" ]]; then
  LATEST_ID="$(jq -r '[.[].videoId | tonumber] | max' "$OUTPUT_FILE" 2>/dev/null)"
  if [[ -n "$LATEST_ID" && "$LATEST_ID" =~ ^[0-9]+$ ]]; then
    START_ID=$((LATEST_ID + 1))
    MERGE_MODE=true
    echo "Resuming from ${OUTPUT_FILE} (latest videoId ${LATEST_ID}): starting at ${START_ID}, will merge" >&2
  else
    echo "WARNING: could not determine latest videoId from ${OUTPUT_FILE}; starting fresh from 10000" >&2
    START_ID=10000
  fi
else
  START_ID=10000
  echo "No ${OUTPUT_FILE} found: starting from ${START_ID}" >&2
fi

if [[ "$START_ID" -gt "$END_ID" ]]; then
  echo "No new IDs to fetch: START_ID (${START_ID}) is already past END_ID (${END_ID})." >&2
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

COLLECTED=0
for (( id = START_ID; id <= END_ID; id++ )); do
  echo "Fetching video ${id}..." >&2

  RESPONSE="$("$FLOW_SCRIPT" "$id")"
  STATUS=$?

  if [[ $STATUS -ne 0 ]]; then
    echo "STOP: yfantasy-flow.sh failed for video ${id} (exit ${STATUS}) — stopping loop." >&2
    break
  fi

  # Append this video's JSON object as one line in the temp file.
  echo "$RESPONSE" >> "$TMP_FILE"
  COLLECTED=$((COLLECTED + 1))
done

echo "Collected ${COLLECTED} video(s)." >&2

# jq definition reducing a segment to the audio fields the check compares.
# Shared by both sides of the comparison so their compact JSON strings match.
AUDIO_DEF='def audio: {audioLanguages: (.audioLanguages // []), publishedAudioVariant};'

# public_audio_info ID — print the audio fields of the video's public segment,
# as compact JSON, from its feed entry. Fails if the request fails or the feed
# answers with a different video (it falls back to another video when the
# requested one doesn't exist).
public_audio_info() {
  local body
  body="$(curl -sf --retry 2 --max-time 30 "${FEED_URL}?limit=1&language=en&videoId=$1")" || return 1
  jq -ce --arg id "$1" "${AUDIO_DEF}"'
    .items[0] | select(.id == $id) | .publicSegment | audio
  ' <<< "$body"
}

# Audio check (see the header comment).
REFETCHED=0
if [[ "$MERGE_MODE" == "true" && -f "$OUTPUT_FILE" ]]; then
  echo "Checking audio info of previously collected videos..." >&2
  while read -r id stored; do
    if ! current="$(public_audio_info "$id")"; then
      echo "WARN: could not read the feed entry for video ${id}; skipping its audio check." >&2
      continue
    fi
    [[ "$current" == "$stored" ]] && continue

    echo "Audio info of video ${id} changed: ${stored} -> ${current}; re-fetching..." >&2
    if ! RESPONSE="$("$FLOW_SCRIPT" "$id")"; then
      echo "WARN: yfantasy-flow.sh failed for video ${id}; keeping its stored object." >&2
      continue
    fi
    echo "$RESPONSE" >> "$TMP_FILE"
    REFETCHED=$((REFETCHED + 1))
  done < <(jq -r --slurpfile fetched "$TMP_FILE" "${AUDIO_DEF}"'
    ($fetched | map(.videoId)) as $skip
    | .[]
    | select(.videoId | IN($skip[]) | not)
    | "\(.videoId) \(.currentSegment | audio | tojson)"
  ' "$OUTPUT_FILE")
  echo "Re-fetched ${REFETCHED} video(s) with changed audio info." >&2
fi

if [[ $((COLLECTED + REFETCHED)) -eq 0 ]]; then
  if [[ "$MERGE_MODE" == "true" && -f "$OUTPUT_FILE" ]]; then
    echo "Nothing new collected; ${OUTPUT_FILE} left unchanged." >&2
  else
    echo "[]" > "$OUTPUT_FILE"
  fi
elif [[ "$MERGE_MODE" == "true" && -f "$OUTPUT_FILE" ]]; then
  # Merge this run's new and re-fetched objects into the existing array:
  # concatenate (new objects first so a re-fetched ID's fresh data wins over
  # stale data on the same ID), dedupe by videoId, and re-sort descending.
  jq -s '.[1:] + (.[0] // []) | unique_by(.videoId) | sort_by(.videoId | tonumber) | reverse' \
    "$OUTPUT_FILE" "$TMP_FILE" > "${OUTPUT_FILE}.new"
  mv "${OUTPUT_FILE}.new" "$OUTPUT_FILE"
else
  # Fresh start (rule 3, or no existing file to merge into): slurp the
  # newline-delimited JSON objects into one array, reversed so the last
  # successfully fetched video comes first.
  jq -s 'reverse' "$TMP_FILE" > "$OUTPUT_FILE"
fi

echo "Wrote $(jq 'length' "$OUTPUT_FILE") item(s) to ${OUTPUT_FILE}" >&2
