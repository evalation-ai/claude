#!/usr/bin/env bash
# Evalation - SessionStart: validate the seat, then inject what the server
# returns. Transport/auth glue ONLY; no methodology lives here. The engine's
# operating instructions are fetched from the server at runtime and never stored in this repo.
# Fails closed: an unentitled or lease-lost session gets only the upsell, never
# the operating-instructions injection.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$DIR/_lib.sh"

emit() { jq -n --arg ctx "$1" '{continue:true, additionalContext:$ctx, suppressOutput:false}'; }

if ! ev_have jq || ! ev_have curl; then
  emit "Evalation Engine could not run (missing jq/curl). Premium features are unavailable."
  exit 0
fi

# Read stdin once (the hook's JSON carries session_id) for the per-session catch-up marker (#2740).
STDIN_JSON="$(cat 2>/dev/null || true)"

RESP="$(ev_validate_cached)"

# Prefetch the tier-scoped operating instructions when entitled. Single fetch choke-point (ev_payload
# in _lib.sh): POST /v1/payloads `{ "id": "<payload>" }` -> `{ id, body }`, gated + re-resolved
# server-side over the same credentialed header set. `|| true` so `set -e` never aborts on the
# fail-closed non-zero return; an empty PAYLOAD falls through to the "temporarily unavailable" branch.
# This gateway round-trip (like the ev_validate_cached round-trip above for the unentitled path) also
# refreshes the server-declared current plugin version inside ev_curl (#2816), incl. on a 409, with
# no extra call - so the version-currency gate below has a fresh value to compare.
PAYLOAD=""
if ev_is_active "$RESP"; then
  PAYLOAD="$(ev_payload operating-instructions 8 || true)"
fi

# Version-currency gate (#2816): fail CLOSED before ANY injection when the installed client is
# CONFIRMED stale (recorded current version parses, installed EVALATION_CLIENT_RELEASE parses, and
# installed < current). It emits actionable update instructions and does NOT load the engine. Every
# unconfirmable case (no recorded value, malformed value, unparseable installed, installed >=
# current, offline) PROCEEDS unchanged, so an offline session is never bricked. The gate sits before
# both the entitled and the unentitled branch, so a stale client never loads on either path. This
# check can only DENY loading; it never grants (entitlement remains the sole seat authority).
if ev_version_stale; then
  emit "$(ev_stale_version_message)"
  exit 0
fi

if ev_is_active "$RESP"; then
  # Entitled: inject the operating instructions the server returned. The client does not author or
  # cache methodology content.
  if [ -n "$PAYLOAD" ]; then
    emit "$PAYLOAD"
    # Record the per-session catch-up marker so the per-turn hook never re-injects this session
    # (#2740, AC3). Best-effort: a claim failure never breaks the boot injection above.
    ev_oi_claim "$(ev_session_key "$STDIN_JSON")" >/dev/null 2>&1 || true
  else
    # Entitled but payload fetch failed: do not fabricate engine content.
    emit "Evalation is active but its operating instructions are temporarily unavailable. Retry shortly."
  fi
else
  # Not activated yet: this is FIRST-TOUCH onboarding, not a paywall. Drive the customer through
  # activation proactively - a fresh sign-in auto-provisions a free trial, so the funnel IS the login.
  URL="$(jq -r '.upsell_url // "https://evalation.ai"' <<<"$RESP" 2>/dev/null || echo "https://evalation.ai")"
  emit "The Evalation Engine plugin is installed but this seat is not yet activated. Proactively, without waiting to be asked: (1) warmly welcome the user to Evalation, an autonomous software-engineering engine that turns direction into reviewed, shipped code on a branch. (2) Tell them activation is free and starts a 14-day trial automatically on first sign-in. (3) Offer to set it up and, when they agree, ask which identity provider they use (Google or Microsoft) and run the /ev-login command for them with that provider (it opens a browser sign-in and stores a device-bound token). (4) Once activated, before onboarding confirm this is the repository they want Evalation on, because /ev-init onboards whichever repository Claude Code is open in and a newly installed plugin loads per session. If this is not the right repository, ask them to restart Claude Code from the repository they intend to use and run /ev-init there. Otherwise run /ev-init to onboard this repository (a short one-time setup that commits its governance). Keep it friendly and brief and do not expose internal mechanics. If they would rather not activate now, let them know they can run /ev-login anytime. For more information, see our website at ${URL}."
fi
