#!/usr/bin/env bash
#
# yfantasy-flow.sh — walk the guest unlock flow for a yfantasy.me video.
#
# Usage:   ./yfantasy-flow.sh <VIDEO_ID>
# Example: ./yfantasy-flow.sh 10054
#
# The flow creates a fresh anonymous guest, claims the free first hidden
# segment, advances once with `continue`, and finally reads the session
# state. The script aborts (non-zero exit) as soon as any step returns a
# non-2xx HTTP status.
#
# Requires: bash, curl, uuidgen, sed
#
set -euo pipefail

# VERBOSE — set manually here (not a CLI flag).
#   1 = print each step's label, response body and HTTP status as it runs.
#   0 = stay quiet through steps 1-3; print only the final step 4 response
#       body (just the JSON, no extra framing) at the end.
VERBOSE=0

# Retry-with-backoff settings for steps that see transient (non-video-specific)
# failures: 1 (auth), 3 (continue) and 4 (session). Step 2 (claim) never
# retries — a non-2xx there means the videoId genuinely doesn't exist /
# mismatched segment, and must fail immediately, not be retried.
RETRY_MAX_ATTEMPTS=3   # total attempts, including the first
RETRY_BASE_DELAY=1     # seconds; doubles each retry (1s, 2s, 4s, ...)

BASE="https://yfantasy.me"

VIDEO_ID="${1:-}"
if [[ -z "$VIDEO_ID" ]]; then
  echo "Usage: $0 <VIDEO_ID>" >&2
  exit 1
fi

# A random per-guest token. It is sent both as a cookie and (at auth time) in the
# body, and it becomes the identity of the throwaway anonymous account.
TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
COOKIE="your-fantasy-single-video-buyer-token=${TOKEN}"

if [[ "$VERBOSE" -eq 1 ]]; then
  echo "Video ID    : ${VIDEO_ID}"
  echo "Guest token : ${TOKEN}"
  echo
fi

# request RETRY_MODE LABEL -- <curl args...>
#   RETRY_MODE: "retry" = retry on non-2xx with exponential backoff, up to
#               RETRY_MAX_ATTEMPTS total attempts (for steps 1, 3, 4 — those
#               can hit transient server hiccups unrelated to the videoId).
#               "no-retry" = fail immediately on the first non-2xx (for step
#               2 — a non-2xx there is a real, permanent rejection: the video
#               or segment doesn't exist, so retrying would be pointless).
# Runs curl and exits the script with an error if every attempt returns a
# non-2xx HTTP status. When VERBOSE=1, also prints the label, response body
# and HTTP status for each attempt as it runs. On success the response body
# is left in the global $RESPONSE_BODY for the caller to parse (and, for the
# last step, for final output).
request() {
  local retry_mode="$1"; shift
  local label="$1"; shift

  local max_attempts=1
  if [[ "$retry_mode" == "retry" ]]; then
    max_attempts="$RETRY_MAX_ATTEMPTS"
  fi

  local attempt raw status body delay
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    if [[ "$VERBOSE" -eq 1 ]]; then
      if [[ "$attempt" -gt 1 ]]; then
        echo "--- ${label} (attempt ${attempt}/${max_attempts}) ---"
      else
        echo "--- ${label} ---"
      fi
    fi

    # The `|| true` keeps a curl-level failure (connection refused, DNS,
    # timeout — not just a bad HTTP status) from tripping `set -e` and
    # killing the script outright; it falls through to the same retry path
    # below as any other failed attempt instead.
    raw="$(curl -s -w '\n%{http_code}' "$@" || true)"
    status="${raw##*$'\n'}"
    body="${raw%$'\n'*}"
    # curl itself failing (connection refused, DNS, timeout) leaves $status
    # empty rather than a real HTTP code; label that case explicitly.
    local status_display="${status:-<curl error / no response>}"

    if [[ "$VERBOSE" -eq 1 ]]; then
      echo "$body"
      echo "HTTP $status_display"
      echo
    fi

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
      RESPONSE_BODY="$body"
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      delay=$(( RETRY_BASE_DELAY * (2 ** (attempt - 1)) ))
      echo "WARN: ${label} failed with HTTP ${status_display} (attempt ${attempt}/${max_attempts}); retrying in ${delay}s..." >&2
      sleep "$delay"
    fi
  done

  echo "ERROR: ${label} failed with HTTP ${status_display} after ${max_attempts} attempt(s)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# STEP 1 — Create the anonymous account
#
# Registers a guest user keyed by our token and returns a signed `sessionToken`
# (a ~1 year JWT-like bearer). We capture that token for the authenticated
# steps below. Retries on failure: a non-2xx here is not tied to the video
# being fetched, so it's worth a few attempts before giving up.
# ---------------------------------------------------------------------------
request retry "STEP 1: POST /api/auth/anonymous" \
  -X POST "${BASE}/api/auth/anonymous" \
  -H "Content-Type: application/json" \
  -H "Cookie: ${COOKIE}" \
  -d "{\"token\":\"${TOKEN}\",\"language\":\"en\",\"countryCode\":\"VN\"}" \
  --max-time 30
# Pull the bearer token out of the JSON for the next requests.
SESSION="$(echo "$RESPONSE_BODY" | sed -n 's/.*"sessionToken":"\([^"]*\)".*/\1/p')"
AUTH="Authorization: Bearer ${SESSION}"
: <<'SAMPLE_RESPONSE_1'
HTTP 201
{
  "userId": "3706950",
  "email": "guest-<token>@anonymous.local",
  "displayName": "Guest",
  "provider": "email",
  "isNew": true,
  "isAnonymous": true,
  "country": "VN",
  "language": "en",
  "sessionToken": "eyJ2ZXJzaW9uIjoxLCJ1c2VySWQiOiIzNzA2OTUwIiwiaXNzdWVkQXQiOjE3ODkwNTUxOTYsImV4cGlyZXNBdCI6MTgyMDU5MTE5Nn0.<sig>"
}
# sessionToken payload decodes to:
#   {"version":1,"userId":"3706950","issuedAt":1789055196,"expiresAt":1820591196}
SAMPLE_RESPONSE_1

# ---------------------------------------------------------------------------
# STEP 2 — Claim the free first segment onto the account
#
# Binds the anonymous "first free look" (segment_1) to the now-authenticated
# guest. The server validates the segmentId: only the real first hidden segment
# is accepted (claiming e.g. segment_2 returns 400 GUEST_FIRST_UNLOCK_SEGMENT_MISMATCH).
# No retry here: a non-2xx means the videoId (or segment) genuinely doesn't
# exist / doesn't match — a real, permanent rejection, not a transient blip —
# so it must fail immediately.
# ---------------------------------------------------------------------------
request no-retry "STEP 2: POST /api/me/guest-first-unlocks/claim" \
  -X POST "${BASE}/api/me/guest-first-unlocks/claim" \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Cookie: ${COOKIE}" \
  -d "{\"videoId\":\"${VIDEO_ID}\",\"segmentId\":\"${VIDEO_ID}_segment_1\"}" \
  --max-time 30
: <<'SAMPLE_RESPONSE_2'
HTTP 200
{
  "videoId": "10054",
  "unlockedHiddenSegmentCount": 1,
  "segment": {
    "id": "10054_segment_1",
    "segmentIndex": 1,
    "visibility": "hidden",
    "durationMs": 51247,
    "signedUrl": "https://vz-e2d1520f-0ba.b-cdn.net/a970be22-.../playlist.m3u8",
    "fallbackUrl": "https://vz-e2d1520f-0ba.b-cdn.net/a970be22-.../play_720p.mp4"
  }
}
# Wrong segment (e.g. "<id>_segment_2") -> HTTP 400 {"code":"GUEST_FIRST_UNLOCK_SEGMENT_MISMATCH"}
# (the script would abort here since 400 is not 2xx)
SAMPLE_RESPONSE_2

# ---------------------------------------------------------------------------
# STEP 3 — Continue to the next hidden segment
#
# Advances playback and unlocks the next segment. This one reports source:"coin"
# but a fresh guest starts with a 10-coin balance and this second unlock is a
# promo (balance stays 10). Once the balance can't cover the next segment the
# endpoint returns HTTP 402 with a paywall object instead of a segment (which
# would also abort this script, since 402 is not 2xx). Retries on failure,
# since transient non-2xx responses here have been observed that clear up on
# a simple retry.
# ---------------------------------------------------------------------------
request retry "STEP 3: POST /api/videos/${VIDEO_ID}/continue" \
  -X POST "${BASE}/api/videos/${VIDEO_ID}/continue" \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Cookie: ${COOKIE}" --max-time 30
: <<'SAMPLE_RESPONSE_3'
HTTP 200
{
  "outcome": "unlock",
  "source": "coin",
  "coinBalance": 10,
  "unlockedHiddenSegmentCount": 2,
  "segment": {
    "id": "10054_segment_2",
    "segmentIndex": 2,
    "visibility": "hidden",
    "durationMs": 49784,
    "signedUrl": "https://vz-e2d1520f-0ba.b-cdn.net/1b02df7c-.../playlist.m3u8",
    "fallbackUrl": "https://vz-e2d1520f-0ba.b-cdn.net/1b02df7c-.../play_720p.mp4"
  }
}
# When the balance is exhausted, `continue` returns instead:
# HTTP 402
# {
#   "outcome": "paywall",
#   "requiredCoins": 40,
#   "currentCoinBalance": 10,
#   "coveringPlanCodes": [],
#   "isCoveredByAnyMonthlyPlan": false,
#   "secondRechargeOfferAvailable": false
# }
SAMPLE_RESPONSE_3

# ---------------------------------------------------------------------------
# STEP 4 — Read the session state
#
# Returns the whole video: title, tags, the current (public) segment and the
# list of hidden segments. Unlocked segments carry their signedUrl/fallbackUrl
# and locked:false; locked segments are metadata-only (no asset keys, no signed
# URLs) — the server withholds playback references for anything not yet owned.
# Retries on failure, same rationale as step 1/3.
# ---------------------------------------------------------------------------
request retry "STEP 4: GET /api/videos/${VIDEO_ID}/session?language=en" \
  -X GET "${BASE}/api/videos/${VIDEO_ID}/session?language=en" \
  -H "$AUTH" \
  -H "Cookie: ${COOKIE}" --max-time 30
: <<'SAMPLE_RESPONSE_4'
HTTP 200
{
  "videoId": "10054",
  "title": "No Choice",
  "tags": ["For all", "Romance", "Classic"],
  "currentSegment": {
    "id": "10054_segment_0",
    "segmentIndex": 0,
    "visibility": "public",
    "durationMs": 28840,
    "imageUrl": "https://vz-e2d1520f-0ba.b-cdn.net/89991983-.../thumbnail.jpg",
    "signedUrl": "https://vz-e2d1520f-0ba.b-cdn.net/d0b80180-.../playlist.m3u8",
    "fallbackUrl": "https://vz-e2d1520f-0ba.b-cdn.net/d0b80180-.../play_720p.mp4"
  },
  "unlockedHiddenSegmentCount": 2,
  "nextContinueIndex": 3,
  "hiddenSegments": [
    { "id": "10054_segment_1", "segmentIndex": 1, "locked": false,
      "signedUrl": "https://vz-e2d1520f-0ba.b-cdn.net/a970be22-.../playlist.m3u8",
      "fallbackUrl": "https://vz-e2d1520f-0ba.b-cdn.net/a970be22-.../play_720p.mp4" },
    { "id": "10054_segment_2", "segmentIndex": 2, "locked": false,
      "signedUrl": "https://vz-e2d1520f-0ba.b-cdn.net/1b02df7c-.../playlist.m3u8",
      "fallbackUrl": "https://vz-e2d1520f-0ba.b-cdn.net/1b02df7c-.../play_720p.mp4" },
    { "id": "10054_segment_3", "segmentIndex": 3, "locked": true, "durationMs": 64413 },
    { "id": "10054_segment_4", "segmentIndex": 4, "locked": true, "durationMs": 39521 }
  ]
}
SAMPLE_RESPONSE_4

if [[ "$VERBOSE" -eq 1 ]]; then
  echo "Done."
else
  # Quiet mode: only the final step's response body goes to stdout.
  echo "$RESPONSE_BODY"
fi
