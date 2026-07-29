#!/usr/bin/env bash
# Evalation Engine - shared hook glue (transport / auth / fail-closed only).
#
# This file carries NO methodology, NO premium prompts, NO secrets, and NO signing
# keys. It is pure transport: it calls the remote Evalation entitlement service and
# defaults every entitlement decision to DENY (fail closed). All gating authority is
# server-side; the client never self-grants. Keep it that way.
#
# Public config (overridable by env; defaults are the public prod endpoints):
#   EVALATION_GATEWAY_URL  non-secret gateway base URL (payloads/dashboard/feedback/usage/mcp)
#                          (default https://gateway.evalation.ai)
#   EVALATION_API_URL      entitlement/licensing base URL  (default https://api.evalation.ai)
#   EVALATION_CLIENT_ID    PUBLIC client id (not a secret)  (default evalation-plugin-public)
# Runtime-only (never stored in this repo):
#   the seat token lives in the OS keychain, read via `evalation-token --read`.
set -euo pipefail

# Two endpoints (hybrid backend): the GATEWAY serves the non-secret surface
# (payloads/dashboard/feedback/usage/error-report/mcp), the API base is entitlement/licensing ONLY.
# Both are public, non-secret. The signing key never lives behind the gateway.
EVALATION_GATEWAY_URL="${EVALATION_GATEWAY_URL:-https://gateway.evalation.ai}"
EVALATION_API_URL="${EVALATION_API_URL:-https://api.evalation.ai}"
EVALATION_CLIENT_ID="${EVALATION_CLIENT_ID:-evalation-plugin-public}"

# Client/plugin build identifiers reported on a field-error report (structured only, no PII).
# Public, non-secret; overridable by env (a build can inject the real release/commit).
EVALATION_CLIENT_RELEASE="${EVALATION_CLIENT_RELEASE:-0.0.0}"
EVALATION_CLIENT_COMMIT="${EVALATION_CLIENT_COMMIT:-unknown}"

# Consent / air-gap switch for client error reporting (item #79). Default ON for free/pro with
# disclosure (see README); an enterprise / air-gapped tenant sets it OFF (or ships signed-file
# only) to disable ALL phone-home of client faults. When off, the reporter is a hard no-op (no
# spool, no flush). The org id is NEVER sent by the client - the server derives it from the token.
EVALATION_ERROR_REPORTING="${EVALATION_ERROR_REPORTING:-on}"

# Cache dir for the short-TTL validate result (latency/offline softening only; a
# stale or missing cache NEVER grants - it fails closed). Tmp, per-user.
EV_CACHE_DIR="${EVALATION_CACHE_DIR:-${TMPDIR:-/tmp}/evalation-plugin}"
EV_CACHE_FILE="$EV_CACHE_DIR/entitlement.json"

# The plugin's helper bins (evalation-token, evalation-device-id, evalation-login) are installed to
# ${EVALATION_BIN_DIR:-$HOME/.local/bin} by the login flow. Claude Code's hook environment does NOT
# guarantee that dir is on PATH - the desktop app AND a plain `claude` CLI launch both omit it - so the
# seat check must locate the helpers ITSELF, never depending on the customer's launch PATH. Put the bin
# dir on PATH here (P0: else ev_token is empty -> the server sees an unauthenticated call -> not-entitled
# -> the activation loop where a fresh session keeps reporting the seat inactive).
export PATH="${EVALATION_BIN_DIR:-$HOME/.local/bin}:$PATH"

ev_have() { command -v "$1" >/dev/null 2>&1; }

# Transport security choke-point (#1838, #1963): the seat credentials (Bearer token + license) may ONLY
# leave over TLS. EVERY credentialed request routes through ev_curl, which REFUSES a non-https target
# fail-closed (returns non-zero, sends NOTHING). It scheme-checks the EFFECTIVE TARGET URL it is about
# to fetch (the http(s):// argument), NOT a fixed base global - so BOTH credentialed bases (the
# entitlement API base AND the non-secret gateway base) are TLS-guarded uniformly: a mis-set plaintext
# gateway or api URL can never leak the token/license over plaintext http. Carve-outs: loopback (local
# dev) and EVALATION_ALLOW_INSECURE=1 (an explicit dev/test opt-in). One check here covers all hooks; a
# refused call fails closed exactly like an unreachable server (the caller's not-entitled / no-op path).
ev_curl() {
  # The target is the URL positional argument curl will fetch (headers/flags never look like a URL);
  # the last http(s):// argument wins. An absent target fails closed (refused unless opt-in).
  local _arg _target=""
  for _arg in "$@"; do
    case "$_arg" in http://*|https://*) _target="$_arg" ;; esac
  done
  case "$_target" in
    https://*) : ;;                                             # TLS: always allowed
    http://127.0.0.1*|http://localhost*|"http://[::1]"*) : ;;   # loopback: local dev / staged server
    *) [ "${EVALATION_ALLOW_INSECURE:-0}" = "1" ] || return 7 ;; # non-https, non-loopback -> refuse (no send)
  esac
  command curl "$@"
}

# Spool file for client-fault reports (item #79). Separate from the usage spool so the two
# fire-and-forget channels never interfere. Tmp, per-user.
EV_ERROR_SPOOL="$EV_CACHE_DIR/error-report-spool.ndjson"

# True when client error reporting is enabled (consent / air-gap gate). An enterprise/air-gapped
# tenant turns this off and the reporter becomes a hard no-op.
ev_error_reporting_on() {
  case "$(printf '%s' "${EVALATION_ERROR_REPORTING:-on}" | tr '[:upper:]' '[:lower:]')" in
    1|true|on|yes) return 0;;
    *) return 1;;
  esac
}

# Sanitize one structured code value, first line of defense (the server-side redaction gateway is
# the backstop). A structured code is a SINGLE token: take only the first whitespace-delimited
# field FIRST (so anything a caller appends after a space - a smuggled secret, path, or prompt - is
# dropped wholesale rather than glued onto the code), THEN keep only a tight transport-safe
# alphabet and bound the length. Never emits free text.
ev_error_sanitize() {
  local first
  # First whitespace-delimited token only; everything after the first space/tab/newline is dropped.
  first="$(printf '%s' "${1:-}" | awk '{print $1; exit}')"
  printf '%s' "$first" | tr -cd 'A-Za-z0-9._:>+-' | cut -c1-128
}

# Spool ONE structured client-fault report. STRUCTURED CODES ONLY:
#   $1 error_code   (e.g. E_HOOK_TIMEOUT)   $2 component (the failing location WITHIN the client)
#   $3 stack_signature (optional, a scrubbed fingerprint - NOT a stack dump)
# It NEVER sends prompt content, tool args, file contents, paths, or PII, and it NEVER sends the
# org id (the server derives that from the token). A hard no-op when reporting is disabled or jq
# is unavailable. Best-effort: any failure is swallowed so a fault report never breaks the turn.
ev_error_report() {
  ev_error_reporting_on || return 0
  ev_have jq || return 0
  local ec comp sig
  ec="$(ev_error_sanitize "${1:-}")"
  comp="$(ev_error_sanitize "${2:-}")"
  sig="$(ev_error_sanitize "${3:-}")"
  [ -n "$ec" ] && [ -n "$comp" ] || return 0
  mkdir -p "$EV_CACHE_DIR" 2>/dev/null || true
  jq -nc \
    --arg ec "$ec" --arg comp "$comp" --arg sig "$sig" \
    --arg rel "$EVALATION_CLIENT_RELEASE" --arg commit "$EVALATION_CLIENT_COMMIT" \
    '{error_code:$ec, component:$comp, release:$rel, commit:$commit}
       + (if $sig == "" then {} else {stack_signature:$sig} end)' \
    >> "$EV_ERROR_SPOOL" 2>/dev/null || return 0
}

# Best-effort background flush of the client-fault spool to /v1/error-report. Sends ONLY the
# structured spooled events (no org id, no PII). Fire-and-forget: never blocks the turn, never
# fails the session. A hard no-op when reporting is disabled or the spool is empty.
ev_error_flush() {
  ev_error_reporting_on || return 0
  ev_have jq || return 0
  ev_have curl || return 0
  [ -s "$EV_ERROR_SPOOL" ] || return 0
  local token payload
  token="$(ev_token)"
  payload="$(jq -sc '{events: [.[] | {error_code, component, release, commit} + (if .stack_signature then {stack_signature} else {} end)]}' "$EV_ERROR_SPOOL" 2>/dev/null || true)"
  [ -n "$payload" ] || return 0
  (
    if ev_curl -fsS -m 4 -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "X-Evalation-Client: ${EVALATION_CLIENT_ID}" \
        -H "X-Evalation-Device: $(ev_device)" \
        -H "$(ev_plugin_version_header)" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "${EVALATION_GATEWAY_URL}/v1/error-report" >/dev/null 2>&1; then
      : > "$EV_ERROR_SPOOL"   # flushed: clear the spool
    fi
  ) >/dev/null 2>&1 &
}

# Read the seat token from the OS keychain helper if present. Empty when absent;
# the server then treats the call as unauthenticated and returns not-entitled.
ev_token() {
  if ev_have evalation-token; then evalation-token --read 2>/dev/null || true; fi
}

ev_device() {
  if ev_have evalation-device-id; then evalation-device-id 2>/dev/null || true; fi
}

# The plugin<->backend version-compat header (item #1666). Echoes the client's OWN version
# identifier (EVALATION_CLIENT_RELEASE - the single client-version source; the client holds NO
# supported range, only its own version). The server enforces the supported range and refuses an
# out-of-range client with a 409 incompatible-plugin-version + actionable remedy. Public, non-secret
# (a plain semver string; zero methodology/IP).
ev_plugin_version_header() {
  printf 'X-Evalation-Plugin-Version: %s' "$EVALATION_CLIENT_RELEASE"
}

# POST /v1/validate. Echoes the raw JSON response on success; echoes a hard
# not-entitled object on ANY failure (network, non-2xx, timeout). Fail closed.
ev_validate() {
  local token resp
  token="$(ev_token)"
  resp="$(ev_curl -fsS -m 5 \
            -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "X-Evalation-Client: ${EVALATION_CLIENT_ID}" \
            -H "X-Evalation-Session: ${EVALATION_SESSION:-$$}" \
            -H "X-Evalation-Device: $(ev_device)" \
            -H "$(ev_plugin_version_header)" \
            "${EVALATION_API_URL}/v1/validate" 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    printf '%s' '{"entitled":false,"reason":"unreachable","lease":"none"}'
    return 0
  fi
  printf '%s' "$resp"
}

# True only when the response says entitled AND the lease is granted. Any other
# state (superseded lease, missing field, malformed JSON) is false: fail closed.
ev_is_active() {
  local resp="$1"
  ev_have jq || return 1
  [ "$(jq -r '.entitled // false' <<<"$resp" 2>/dev/null)" = "true" ] \
    && [ "$(jq -r '.lease // "none"' <<<"$resp" 2>/dev/null)" = "granted" ]
}

# Validate with a short-TTL cache. Writes fresh results to cache; on a network
# failure, returns a *fresh, unexpired* cache entry if one exists, else the
# fail-closed not-entitled object. The cache can only soften latency, never
# override a deny: a cache miss/expiry yields not-entitled.
ev_validate_cached() {
  local ttl now resp cached cached_at age
  mkdir -p "$EV_CACHE_DIR" 2>/dev/null || true
  now="$(date +%s)"

  # FRESH-CACHE FAST PATH (owner license-cadence design 2026-07-14): if a cached ACTIVE grant is still
  # within its TTL, reuse it with NO network call - the license is validated at most once per TTL
  # window (default hourly), not once per tool call / turn. The server still RE-RESOLVES entitlement
  # authoritatively on every premium payload + /v1/mcp/tool-call, so this cache is a client-UX
  # throttle, never the security boundary. EVALATION_FORCE_VALIDATE=1 forces a live check (login /
  # an explicit re-check) regardless of the cache.
  if [ "${EVALATION_FORCE_VALIDATE:-0}" != "1" ] && [ -f "$EV_CACHE_FILE" ]; then
    cached="$(cat "$EV_CACHE_FILE" 2>/dev/null || true)"
    if [ -n "$cached" ] && ev_is_active "$cached"; then
      cached_at="$(jq -r '.cached_at // 0' <<<"$cached" 2>/dev/null || echo 0)"
      ttl="$(jq -r '.cache_ttl_seconds // 0' <<<"$cached" 2>/dev/null || echo 0)"
      age=$(( now - cached_at ))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  resp="$(ev_validate)"
  if ev_is_active "$resp"; then
    ttl="$(jq -r '.cache_ttl_seconds // 3600' <<<"$resp" 2>/dev/null || echo 3600)"
    printf '%s' "$resp" | jq -c --arg at "$now" --arg ttl "$ttl" \
      '. + {cached_at:($at|tonumber), cache_ttl_seconds:($ttl|tonumber)}' \
      > "$EV_CACHE_FILE" 2>/dev/null || true
    printf '%s' "$resp"
    return 0
  fi

  # Live call did not return an active entitlement. If it was a transport failure
  # (unreachable), a still-valid cache may carry the session; a definitive deny
  # (entitled:false with a reason other than unreachable) must NOT be softened.
  if [ "$(jq -r '.reason // ""' <<<"$resp" 2>/dev/null)" = "unreachable" ] \
     && [ -f "$EV_CACHE_FILE" ]; then
    cached="$(cat "$EV_CACHE_FILE" 2>/dev/null || true)"
    if [ -n "$cached" ] && ev_is_active "$cached"; then
      cached_at="$(jq -r '.cached_at // 0' <<<"$cached" 2>/dev/null || echo 0)"
      ttl="$(jq -r '.cache_ttl_seconds // 0' <<<"$cached" 2>/dev/null || echo 0)"
      age=$(( now - cached_at ))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  # No live grant, no fresh cache: fail closed.
  printf '%s' "$resp"
}
