#!/usr/bin/env bash
#
# yfantasy-flow.sh — fetch the video information for one yfantasy.me video.
#
# Usage:   ./yfantasy-flow.sh <VIDEO_ID>
# Example: ./yfantasy-flow.sh 10054
#
# The flow creates a fresh anonymous guest, claims the free first hidden
# segment (the session endpoint answers VIDEO_NOT_FOUND until something has
# been claimed), unlocks every further segment `continue` will give a guest,
# then reads the session state and strips it down to video information. The
# script aborts (non-zero exit) as soon as any step returns a non-2xx HTTP
# status (except the 402 paywall that ends the `continue` loop).
#
# The session keeps its original structure, but segment URLs (signedUrl /
# fallbackUrl / imageUrl) are signed with an expiry and asset keys rotate, so
# they are dropped. Only these fields are kept; a field the server omits (e.g.
# the audio fields on a locked segment) stays omitted:
#   video   : videoId, title, tags, currentSegment, unlockedHiddenSegmentCount,
#             hiddenSegments
#   segment : id, segmentIndex, visibility, locked, aspectRatio, width, height,
#             durationMs, audioLanguages, publishedAudioVariant,
#             speechLanguage, hasHumanSpeech
# Curly single quotes (‘ ’) in the title are normalized to a plain '.
#
# Requires: bash, curl, uuidgen, sed, jq
#
set -euo pipefail

# VERBOSE — set manually here (not a CLI flag).
#   1 = print each step's label, response body and HTTP status as it runs,
#       followed by the stripped session.
#   0 = stay quiet; print only the stripped session (just the JSON, no extra
#       framing) at the end.
VERBOSE=0

# Retry-with-backoff settings for steps that see transient (non-video-specific)
# failures: 1 (auth), 3 (continue) and 4 (session). Step 2 (claim) never
# retries — a non-2xx there means the videoId genuinely doesn't exist /
# mismatched segment, and must fail immediately, not be retried.
RETRY_MAX_ATTEMPTS=3   # total attempts, including the first
RETRY_BASE_DELAY=1     # seconds; doubles each retry (1s, 2s, 4s, ...)

# Upper bound on step 3 unlocks, so the `continue` loop can't run forever if
# the server never answers with a paywall. A guest only ever gets one.
CONTINUE_MAX_UNLOCKS=10

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
#               RETRY_MAX_ATTEMPTS total attempts (for steps 1 and 4 — those
#               can hit transient server hiccups unrelated to the videoId).
#               "until-paywall" = like "retry", except HTTP 402 (the paywall)
#               is an expected answer: it returns 1 right away, without
#               retrying or exiting, so the step 3 loop can stop.
#               "no-retry" = fail immediately on the first non-2xx (for step
#               2 — a non-2xx there is a real, permanent rejection: the video
#               or segment doesn't exist, so retrying would be pointless).
# Runs curl and exits the script with an error if every attempt returns a
# non-2xx HTTP status. When VERBOSE=1, also prints the label, response body
# and HTTP status for each attempt as it runs. On success the response body
# is left in the global $RESPONSE_BODY for the caller to parse.
request() {
  local retry_mode="$1"; shift
  local label="$1"; shift

  local max_attempts=1
  if [[ "$retry_mode" != "no-retry" ]]; then
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

    if [[ "$retry_mode" == "until-paywall" && "$status" == "402" ]]; then
      RESPONSE_BODY="$body"
      return 1
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
  "userId": "6442139",
  "email": "guest-<token>@anonymous.local",
  "displayName": "Guest",
  "avatarUrl": null,
  "provider": "email",
  "isNew": true,
  "isAnonymous": true,
  "country": "VN",
  "language": "en",
  "sessionToken": "eyJ2ZXJzaW9uIjoxLCJ1c2VySWQiOiI2NDQyMTM5Iiwic2Vzc2lvblZlcnNpb24iOjAsImlzc3VlZEF0IjoxNzkyMzQzNDE0LCJleHBpcmVzQXQiOjE4MjM4Nzk0MTR9.<sig>"
}
# sessionToken payload decodes to:
#   {"version":1,"userId":"6442139","sessionVersion":0,"issuedAt":1792343414,"expiresAt":1823879414}
SAMPLE_RESPONSE_1

# ---------------------------------------------------------------------------
# STEP 2 — Claim the free first segment onto the account
#
# Binds the anonymous "first free look" (segment_1) to the now-authenticated
# guest. Without this the session endpoint in step 4 returns 404
# VIDEO_NOT_FOUND. The server validates the segmentId: only the real first
# hidden segment is accepted (claiming e.g. segment_2 returns 400
# GUEST_FIRST_UNLOCK_SEGMENT_MISMATCH).
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
    "id": "10054_segment_1", "segmentIndex": 1, "visibility": "hidden",
    "mediaType": "video", "aspectRatio": "9:16", "width": 900, "height": 1600,
    "durationMs": 51247, "audioLanguages": ["zh", "en", "ja", "ko"], "speechLanguage": "zh",
    "assetKey": "...", "signedUrl": "<expiring>", "fallbackUrl": "<expiring>", ...
  }
}
# Past the last real video -> HTTP 400 {"code":"VIDEO_NOT_FOUND"}
# Wrong segment (e.g. "<id>_segment_2") -> HTTP 400 {"code":"GUEST_FIRST_UNLOCK_SEGMENT_MISMATCH"}
# (the script would abort here since 400 is not 2xx)
SAMPLE_RESPONSE_2

# ---------------------------------------------------------------------------
# STEP 3 — Continue through every unlockable hidden segment
#
# Each call advances playback and unlocks the next segment. It reports
# source:"coin", but a fresh guest starts with a 10-coin balance and the
# second unlock is a promo (balance stays 10). Once the balance can't cover
# the next segment the endpoint answers HTTP 402 with a paywall object, which
# ends the loop — in practice right after that one promo unlock. The loop also
# stops on any 2xx outcome other than "unlock", and after CONTINUE_MAX_UNLOCKS
# unlocks. Other non-2xx responses are retried, since transient ones have been
# observed here that clear up on a simple retry.
# ---------------------------------------------------------------------------
for (( unlock = 1; unlock <= CONTINUE_MAX_UNLOCKS; unlock++ )); do
  request until-paywall "STEP 3: POST /api/videos/${VIDEO_ID}/continue" \
    -X POST "${BASE}/api/videos/${VIDEO_ID}/continue" \
    -H "Content-Type: application/json" \
    -H "$AUTH" \
    -H "Cookie: ${COOKIE}" --max-time 30 || break
  [[ "$(jq -r '.outcome' <<< "$RESPONSE_BODY")" == "unlock" ]] || break
done
: <<'SAMPLE_RESPONSE_3'
HTTP 200
{
  "outcome": "unlock",
  "source": "coin",
  "coinBalance": 10,
  "unlockedHiddenSegmentCount": 2,
  "nextContinueIndex": 3,
  "accessExpiresAt": null,
  "segment": {
    "id": "10054_segment_2", "segmentIndex": 2, "visibility": "hidden", "durationMs": 49784,
    "assetKey": "...", "signedUrl": "<expiring>", "fallbackUrl": "<expiring>", ...
  }
}
# The next call, once the balance can't cover the next segment:
HTTP 402
{
  "outcome": "paywall",
  "requiredCoins": 40,
  "currentCoinBalance": 10,
  "coveringPlanCodes": ["unlimited_monthly"],
  "isCoveredByAnyMonthlyPlan": true,
  "secondRechargeOfferAvailable": false
}
SAMPLE_RESPONSE_3

# ---------------------------------------------------------------------------
# STEP 4 — Read the session state
#
# Returns the whole video: title, tags, the current (public) segment_0 and the
# list of hidden segments. Every segment, locked or not, carries durationMs
# and dimensions; only unlocked ones (segment_0 and the segments unlocked in
# steps 2-3) carry the audio fields.
# Retries on failure, same rationale as step 1.
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
    "id": "10054_segment_0", "segmentIndex": 0, "visibility": "public",
    "mediaType": "video", "aspectRatio": "9:16", "width": 900, "height": 1600,
    "durationMs": 28840, "audioLanguages": ["zh", "en", "ja", "ko"], "speechLanguage": "zh",
    "assetKey": "...", "imageUrl": "<expiring>", "signedUrl": "<expiring>", "fallbackUrl": "<expiring>", ...
  },
  "unlockedHiddenSegmentCount": 2,
  "nextContinueIndex": 3,
  "accessExpiresAt": null,
  "hiddenSegments": [
    { "id": "10054_segment_1", "segmentIndex": 1, "locked": false, "durationMs": 51247,
      "signedUrl": "<expiring>", "fallbackUrl": "<expiring>", ... },
    { "id": "10054_segment_2", "segmentIndex": 2, "locked": false, "durationMs": 49784,
      "signedUrl": "<expiring>", "fallbackUrl": "<expiring>", ... },
    { "id": "10054_segment_3", "segmentIndex": 3, "locked": true, "durationMs": 64413, ... },
    { "id": "10054_segment_4", "segmentIndex": 4, "locked": true, "durationMs": 39521, ... }
  ]
}
SAMPLE_RESPONSE_4

# Strip the session down to the kept fields (see header comment). Filtering
# entries instead of building new objects preserves the server's key order and
# leaves out keys the server didn't send rather than adding them as null.
jq -c --arg apostrophe "'" '
  def only($names): with_entries(select(.key | IN($names[])));
  ["id", "segmentIndex", "visibility", "locked", "aspectRatio", "width",
   "height", "durationMs", "audioLanguages", "publishedAudioVariant",
   "speechLanguage", "hasHumanSpeech"] as $segment_fields
  | only(["videoId", "title", "tags", "currentSegment",
          "unlockedHiddenSegmentCount", "hiddenSegments"])
  | (.title | strings) |= gsub("[‘’]"; $apostrophe)
  | .currentSegment |= only($segment_fields)
  | .hiddenSegments |= map(only($segment_fields))
' <<< "$RESPONSE_BODY"
