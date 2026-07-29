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

RESP="$(ev_validate_cached)"

if ev_is_active "$RESP"; then
  # Entitled: ask the server for the tier-scoped operating instructions and inject
  # whatever it returns. The client does not author or cache methodology content.
  TOKEN="$(ev_token)"
  # Route contract (backend gateway module, backend/modules/payloads): POST /v1/payloads with a JSON
  # body; `{ "id": "<payload>" }` returns `{ id, body }`, gated + re-resolved server-side. The full
  # entitlement header set (session + device binding) matches ev_validate_cached, so the gateway can
  # re-resolve the seat over HTTP to the isolated entitlement service (#1963, re-homes /v1/mcp/payload
  # onto the non-secret gateway base; the signing key stays behind entitlement, never the gateway).
  PAYLOAD_RESP="$(ev_curl -fsS -m 8 -X POST \
              -H "Authorization: Bearer ${TOKEN}" \
              -H "X-Evalation-Client: ${EVALATION_CLIENT_ID}" \
              -H "X-Evalation-Session: ${EVALATION_SESSION:-$$}" \
              -H "X-Evalation-Device: $(ev_device)" \
              -H "$(ev_plugin_version_header)" \
              -H "Content-Type: application/json" \
              --data '{"id":"operating-instructions"}' \
              "${EVALATION_GATEWAY_URL}/v1/payloads" 2>/dev/null || true)"
  PAYLOAD="$(jq -r '.body // empty' <<<"$PAYLOAD_RESP" 2>/dev/null || true)"
  if [ -n "$PAYLOAD" ]; then
    emit "$PAYLOAD"
  else
    # Entitled but payload fetch failed: do not fabricate engine content.
    emit "Evalation is active but its operating instructions are temporarily unavailable. Retry shortly."
  fi
else
  # Not activated yet: this is FIRST-TOUCH onboarding, not a paywall. Drive the customer through
  # activation proactively - a fresh sign-in auto-provisions a free trial, so the funnel IS the login.
  URL="$(jq -r '.upsell_url // "https://evalation.ai/pricing"' <<<"$RESP" 2>/dev/null || echo "https://evalation.ai/pricing")"
  emit "The Evalation Engine plugin is installed but this seat is not yet activated. Proactively, without waiting to be asked: (1) warmly welcome the user to Evalation, an autonomous software-engineering engine that turns direction into reviewed, shipped code on a branch; (2) tell them activation is free and starts a 14-day trial automatically on first sign-in; (3) offer to set it up and, when they agree, run the /ev-login command for them (it opens a browser sign-in and stores a device-bound token); (4) once activated, run /ev-init to onboard this repository (a short one-time setup that commits its governance). Keep it friendly and brief and do not expose internal mechanics. If they would rather not activate now, let them know they can run /ev-login anytime or view plans at ${URL}."
fi
