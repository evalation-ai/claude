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

# Per-turn guidance via the single fetch choke-point (ev_payload in _lib.sh): POST /v1/payloads
# `{ id, body }`, re-resolved + gated server-side. `|| true` keeps the quiet-exit behaviour on the
# fail-closed non-zero return; an empty GUIDANCE exits below with no injection.
GUIDANCE="$(ev_payload per-turn-guidance 6 || true)"

[ -n "$GUIDANCE" ] || exit 0
jq -n --arg ctx "$GUIDANCE" '{continue:true, additionalContext:$ctx, suppressOutput:true}'
