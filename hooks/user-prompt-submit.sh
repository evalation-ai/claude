#!/usr/bin/env bash
# Evalation Engine - UserPromptSubmit: per-turn injection from the server. Re-validates
# through the short-TTL cache and, when active, injects the server's per-turn guidance.
# It ALSO does a one-time per-session operating-instructions catch-up (#2740) so a session
# that activated MID-session (e.g. after /ev-login stored the seat token AFTER SessionStart
# already ran token-less) becomes active on the NEXT turn with no restart. Transport glue
# ONLY. Fails closed: nothing is injected for an unentitled / lease-lost session. Stays quiet
# (no additionalContext) when there is nothing to inject so it never adds noise to a normal turn.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$DIR/_lib.sh"

ev_have jq || exit 0
ev_have curl || exit 0

# Read stdin once (the hook's JSON carries session_id); keep it for the per-session key. `|| true`
# so an absent/empty stdin never trips set -e - the key then falls back to $EVALATION_SESSION/$PPID.
STDIN_JSON="$(cat 2>/dev/null || true)"

RESP="$(ev_validate_cached)"
ev_is_active "$RESP" || exit 0   # fail closed: no injection when not active

# One-time operating-instructions catch-up. Only when NO catch-up was recorded this session AND a
# non-empty body arrives do we CLAIM the marker (atomic mkdir): a transient fetch failure never
# burns the one-shot (AC5), and a re-entry / already-booted session never double-injects (AC2/AC3).
# The claim short-circuits after the body arrives, so an empty PAYLOAD leaves no marker.
KEY="$(ev_session_key "$STDIN_JSON")"
PAYLOAD=""
if ! ev_oi_marked "$KEY"; then
  PAYLOAD="$(ev_payload operating-instructions 8 || true)"
  if [ -n "$PAYLOAD" ] && ev_oi_claim "$KEY"; then
    :                              # first claim this session: keep PAYLOAD for the emit
  else
    PAYLOAD=""                     # already claimed elsewhere, or empty fetch: inject nothing extra
  fi
fi

# Per-turn guidance via the single fetch choke-point (ev_payload in _lib.sh): POST /v1/payloads
# `{ id, body }`, re-resolved + gated server-side. `|| true` keeps the quiet-exit behaviour on the
# fail-closed non-zero return; an empty GUIDANCE contributes nothing below.
GUIDANCE="$(ev_payload per-turn-guidance 6 || true)"

# Quiet exit when there is nothing to inject.
[ -n "$PAYLOAD" ] || [ -n "$GUIDANCE" ] || exit 0

# Emit ONE object with both bodies bound as jq args and concatenated inside additionalContext. The
# bodies are NEVER printed by echo/printf/cat (output-hygiene.sh deny-list covers PAYLOAD/GUIDANCE).
jq -n --arg oi "$PAYLOAD" --arg g "$GUIDANCE" \
  '{continue:true, additionalContext:(($oi // "") + (if $oi != "" and $g != "" then "\n\n" else "" end) + ($g // "")), suppressOutput:true}'
