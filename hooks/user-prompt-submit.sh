#!/usr/bin/env bash
# Evalation Engine - UserPromptSubmit: per-turn injection from the server. Re-validates
# through the short-TTL cache and, when active, injects the server's per-turn guidance.
# Transport glue ONLY. Fails closed: nothing is injected for an unentitled / lease-lost
# session. Stays quiet (no additionalContext) when there is nothing to inject so it
# never adds noise to a normal turn.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$DIR/_lib.sh"

ev_have jq || exit 0
ev_have curl || exit 0

RESP="$(ev_validate_cached)"
ev_is_active "$RESP" || exit 0   # fail closed: no injection when not active

TOKEN="$(ev_token)"
# Per-turn guidance is served as a payload over the gateway's POST /v1/payloads module (#1963, the
# #1961 mounted module; identical `{ id, body }` shape re-resolved + gated server-side). It re-homes
# the old /v1/mcp/payload route onto the non-secret gateway base; the signing key stays isolated
# behind the separate entitlement service, never behind the gateway.
GUIDANCE_RESP="$(ev_curl -fsS -m 6 -X POST \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "X-Evalation-Client: ${EVALATION_CLIENT_ID}" \
            -H "X-Evalation-Session: ${EVALATION_SESSION:-$$}" \
            -H "X-Evalation-Device: $(ev_device)" \
            -H "$(ev_plugin_version_header)" \
            -H "Content-Type: application/json" \
            --data '{"id":"per-turn-guidance"}' \
            "${EVALATION_GATEWAY_URL}/v1/payloads" 2>/dev/null || true)"
GUIDANCE="$(jq -r '.body // empty' <<<"$GUIDANCE_RESP" 2>/dev/null || true)"

[ -n "$GUIDANCE" ] || exit 0
jq -n --arg ctx "$GUIDANCE" '{continue:true, additionalContext:$ctx, suppressOutput:true}'
