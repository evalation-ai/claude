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

# Client/plugin build identifiers. The release is the client's SINGLE version source: it is sent as
# X-Evalation-Plugin-Version on every gateway call, and the gateway REJECTS an out-of-range client with
# 409 incompatible-plugin-version BEFORE dispatch. A bare 0.0.0 default is below the supported floor, so
# the whole premium surface (operating-instructions payload, mcp) 409s and never loads. Derive the real
# version from the co-located plugin manifest (.claude-plugin/plugin.json, shipped beside these hooks) so
# an installed client always reports its true, in-range version. Precedence: an explicit env override
# (a build may inject one) wins; else the manifest; else fail-soft to 0.0.0. Public, non-secret, no PII.
_ev_manifest_version() {
  local mf
  mf="$(dirname -- "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json"
  [ -f "$mf" ] || return 1
  # Trusted, self-authored JSON; parse without a jq dependency (jq is not guaranteed at source time).
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9A-Za-z.-]*\)".*/\1/p' "$mf" | head -1
}
_ev_release="$(_ev_manifest_version 2>/dev/null || true)"
EVALATION_CLIENT_RELEASE="${EVALATION_CLIENT_RELEASE:-${_ev_release:-0.0.0}}"
unset _ev_release
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
# Per-user record of the server-declared current plugin version (item #2816). ev_curl writes the
# X-Evalation-Plugin-Current header value here (validated to strict semver) on every call, and
# SessionStart reads it to fail closed on a confirmed-stale client. A public semver, no secret/PII.
EV_SERVER_VERSION_FILE="$EV_CACHE_DIR/server-plugin-version"

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
  # AFTER the TLS/loopback refusal (never before - no credential leaks over plaintext): dump the
  # response headers so ev_record_server_version can learn the current plugin version (#2816). This
  # is contract-preserving by construction - curl's EXIT STATUS and STDOUT are unchanged (-D writes
  # to a separate file). Best-effort: if mktemp fails, fall back to the plain call. Never let set -e
  # change the caller's contract (capture rc with the || idiom; the record step can never fail it).
  local _hdr _rc=0
  _hdr="$(mktemp 2>/dev/null || true)"
  if [ -z "$_hdr" ]; then
    command curl "$@"
    return $?
  fi
  command curl -D "$_hdr" "$@" || _rc=$?
  ev_record_server_version "$_hdr" || true
  rm -f "$_hdr" 2>/dev/null || true
  return "$_rc"
}

# --- Server-declared current-plugin-version currency check (item #2816) ---------------------------
# All EXTERNAL INPUT treated as DATA (P0015): the header value is regex-validated to strict semver
# before it is ever stored or compared, never eval'd, never interpolated into a command. The check
# can only DENY loading a stale client; it NEVER grants (entitlement stays the sole seat authority).

# Record the server's X-Evalation-Plugin-Current header from a curl header-dump file. Reads it
# case-insensitively, strips CR/whitespace, and stores it ONLY when it is a strict N.N.N semver
# (anything else is ignored -> fail-closed to "unknown"). Atomic write (temp + mv). Best-effort:
# always returns 0 so it can never alter ev_curl's exit contract.
ev_record_server_version() {
  local _file="${1:-}" _val="" _tmp
  [ -n "$_file" ] && [ -f "$_file" ] || return 0
  # Case-insensitive header match; last occurrence wins (redirect chains). Strip the name up to the
  # first colon, then all CR/whitespace. grep -i is portable (macOS/Linux); awk IGNORECASE is not.
  _val="$(grep -i '^X-Evalation-Plugin-Current:' "$_file" 2>/dev/null | tail -1             | sed 's/^[^:]*://' | tr -d '\r' | tr -d '[:space:]')"
  printf '%s' "$_val" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 0
  mkdir -p "$EV_CACHE_DIR" 2>/dev/null || return 0
  _tmp="$(mktemp "$EV_CACHE_DIR/.svv.XXXXXX" 2>/dev/null || true)"
  [ -n "$_tmp" ] || return 0
  if printf '%s' "$_val" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$EV_SERVER_VERSION_FILE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
  else
    rm -f "$_tmp" 2>/dev/null || true
  fi
  return 0
}

# ev_semver_lt A B: 0 (true) IFF A and B are BOTH strict N.N.N semvers AND A < B; non-zero in every
# other case (either unparseable, or A >= B). Numeric field-by-field compare (never lexical). The
# if/then form avoids a set -e abort on an equal-field short-circuit.
ev_semver_lt() {
  local _a="${1:-}" _b="${2:-}" _a1 _a2 _a3 _b1 _b2 _b3
  printf '%s' "$_a" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  printf '%s' "$_b" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  IFS=. read -r _a1 _a2 _a3 <<EOF
$_a
EOF
  IFS=. read -r _b1 _b2 _b3 <<EOF
$_b
EOF
  if [ "$_a1" -ne "$_b1" ]; then [ "$_a1" -lt "$_b1" ]; return $?; fi
  if [ "$_a2" -ne "$_b2" ]; then [ "$_a2" -lt "$_b2" ]; return $?; fi
  [ "$_a3" -lt "$_b3" ]
}

# ev_version_stale: 0 (stale -> FAIL CLOSED) ONLY when the recorded server version file exists, its
# value parses as strict semver, the installed EVALATION_CLIENT_RELEASE parses, AND installed <
# recorded. 1 (proceed) in EVERY other case (no file, unparseable recorded value, unparseable
# installed, installed >= current). This is the fail-OPEN-on-unconfirmable / fail-CLOSED-on-confirmed
# rule (#2816 AC3/AC4): an offline or unverifiable session is never bricked.
ev_version_stale() {
  local _recorded=""
  [ -f "$EV_SERVER_VERSION_FILE" ] || return 1
  _recorded="$(cat "$EV_SERVER_VERSION_FILE" 2>/dev/null | tr -d '\r' | tr -d '[:space:]')"
  ev_semver_lt "$EVALATION_CLIENT_RELEASE" "$_recorded"
}

# Customer-facing update text for a confirmed-stale client (#2816). Names the installed version, the
# current version, and the exact update + reload steps. No internals, no methodology, no IP (P0002):
# a plain semver pair and the public /plugin update path.
ev_stale_version_message() {
  local _recorded=""
  [ -f "$EV_SERVER_VERSION_FILE" ] && _recorded="$(cat "$EV_SERVER_VERSION_FILE" 2>/dev/null | tr -d '\r' | tr -d '[:space:]')"
  printf 'Your Evalation Engine plugin is out of date and was not loaded this session. Installed version: %s. Current version: %s. To update: run /plugin, update the Evalation Engine plugin to the latest version, then fully restart Claude Code so the new version loads. After restarting, Evalation will load normally.' \
    "$EVALATION_CLIENT_RELEASE" "$_recorded"
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

# ev_engine_version - resolve the CLIENT engine-version pin to send with a payload fetch (#2835, the
# client half of the #2829 per-version floor-lookup). Delegates to the side-loaded resolver
# scripts/customer-runtime/engine-version-pin.sh (read-or-mint, per-item sticky, from the server version
# ev_payload captured on a prior fetch). Prints the pin on stdout, or nothing (return 1) when
# unresolvable - the caller then OMITS engine_version and the server falls back to its current version
# (the documented #2829 fail-safe). Fail-soft: a missing runtime resolver is simply an omitted field,
# never an error. It sends NO repo/item/path data (AC7).
ev_engine_version() {
  local runtime pinsh base
  runtime="${EVALATION_RUNTIME_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/evalation/runtime}"
  pinsh="$runtime/scripts/customer-runtime/engine-version-pin.sh"
  [ -x "$pinsh" ] || return 1
  base="${EVALATION_ENGINE_STATE_BASE:-$HOME/.local/state/evalation-engine}"
  bash "$pinsh" resolve "$base" 2>/dev/null || return 1
}

# ev_record_engine_version <version> - capture the server's current ENGINE version (from a
# /v1/payloads response body's server_version field) so ev_engine_version can MINT the per-item pin on
# the next step (#2835 AC4). DISTINCT from ev_record_server_version above, which records the
# X-Evalation-Plugin-Current HEADER (#2816); these are different values and must not share a name.
# Mirrors ev_engine_version's runtime/base resolution so both read/write the SAME per-repo state root.
# The pin script fail-safes an absent/invalid version to a no-op, so this never errors or poisons state.
ev_record_engine_version() {
  local version="${1:-}" runtime pinsh base
  [ -n "$version" ] || return 0
  runtime="${EVALATION_RUNTIME_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/evalation/runtime}"
  pinsh="$runtime/scripts/customer-runtime/engine-version-pin.sh"
  [ -x "$pinsh" ] || return 0
  base="${EVALATION_ENGINE_STATE_BASE:-$HOME/.local/state/evalation-engine}"
  bash "$pinsh" record "$base" "$version" 2>/dev/null || true
}

# ev_payload <id> [timeout_secs] - the SINGLE payload-fetch choke-point (P0043/P0025).
# Validates the seat (ev_validate_cached / ev_is_active) then POSTs `{"id":"<id>"}` to the
# gateway's /v1/payloads route with the same credentialed header set the other calls use, and
# prints the server body on stdout. Fail closed: returns 1 and prints NOTHING on stdout when the
# seat is inactive, jq/curl is missing, the fetch fails, or the body is empty - the client never
# self-grants and never fabricates a body. The id is passed as DATA via `jq -n --arg` (P0015: never
# a shell/eval sink), and the request goes through ev_curl so the TLS-or-loopback transport guard
# keeps covering it. Default timeout 8s.
ev_payload() {
  local id="${1:-}" timeout="${2:-8}" resp token body data
  [ -n "$id" ] || return 1
  ev_have jq || return 1
  ev_have curl || return 1
  resp="$(ev_validate_cached)"
  ev_is_active "$resp" || return 1
  token="$(ev_token)"
  data="$(jq -nc --arg id "$id" '{id:$id}')"
  # #2835 client version-pin: add engine_version to the POST body when a per-item pin resolves. The
  # pin is dotted-numeric-validated here (defense in depth, P0015); an unresolvable/invalid pin OMITS
  # the field so the server falls back to its current version. Exactly ONE outbound field is added -
  # no repo path, slug, item id, branch, diff, or file content ever leaves the device (AC7).
  local pin
  pin="$(ev_engine_version 2>/dev/null || true)"
  if [ -n "$pin" ] && printf '%s' "$pin" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
    data="$(jq -nc --arg id "$id" --arg ev "$pin" '{id:$id, engine_version:$ev}')"
  fi
  resp="$(ev_curl -fsS -m "$timeout" -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "X-Evalation-Client: ${EVALATION_CLIENT_ID}" \
            -H "X-Evalation-Session: ${EVALATION_SESSION:-$$}" \
            -H "X-Evalation-Device: $(ev_device)" \
            -H "$(ev_plugin_version_header)" \
            -H "Content-Type: application/json" \
            --data "$data" \
            "${EVALATION_GATEWAY_URL}/v1/payloads" 2>/dev/null || true)"
  body="$(jq -r '.body // empty' <<<"$resp" 2>/dev/null || true)"
  [ -n "$body" ] || return 1
  # #2835 AC4: capture the server's current version so the NEXT step can mint the per-item pin. A
  # dotted-numeric value only; anything else is ignored by the pin script (fail-safe, content-free).
  local sv
  sv="$(jq -r '.server_version // empty' <<<"$resp" 2>/dev/null || true)"
  [ -n "$sv" ] && ev_record_engine_version "$sv"
  printf '%s' "$body"
}

# --- One-time per-session operating-instructions catch-up marker (item #2740) --------------------
# The per-turn hook makes a session that activated MID-session (e.g. after /ev-login, which stores
# the seat token AFTER SessionStart already ran token-less) become active with no restart, by
# injecting the operating instructions exactly once. These three helpers are the deterministic
# per-session state (P0004): a stable key, a marker read, and an atomic one-shot claim. No
# methodology, no secrets, no PII - the marker is a zero-byte directory named by a sanitized key.

# Derive a stable per-session key. Prefers the hook's stdin session_id (passed as $1 = the raw stdin
# JSON), else $EVALATION_SESSION, else the parent pid. The value is DATA (P0015): sanitized to a
# tight path-safe alphabet, length-bounded, leading dots stripped (no traversal / hidden-file / . /
# ..), never eval'd, never interpolated into a command - only ever used as a single path component.
ev_session_key() {
  local raw="" json="${1:-}"
  if [ -n "$json" ] && ev_have jq; then
    raw="$(jq -r '.session_id // empty' <<<"$json" 2>/dev/null || true)"
  fi
  [ -n "$raw" ] || raw="${EVALATION_SESSION:-}"
  [ -n "$raw" ] || raw="$PPID"
  raw="$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  raw="$(printf '%s' "$raw" | sed 's/^\.*//')"   # strip leading dots (no ./.. / hidden file)
  [ -n "$raw" ] || raw="session"                 # never empty -> a stable fallback token
  printf '%s' "$raw"
}

# True when the operating-instructions catch-up has already been recorded for this session (P0004).
ev_oi_marked() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  [ -d "$EV_CACHE_DIR/sessions/$key.oi" ]
}

# Atomic one-shot claim of the per-session marker: mkdir is atomic, so it succeeds EXACTLY once and
# returns non-zero if already claimed (a re-entry can never double-inject). Best-effort prune of
# markers older than a day so they never accumulate; prune errors are swallowed.
ev_oi_claim() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  mkdir -p "$EV_CACHE_DIR/sessions" 2>/dev/null || return 1
  find "$EV_CACHE_DIR/sessions" -maxdepth 1 -name '*.oi' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
  mkdir "$EV_CACHE_DIR/sessions/$key.oi" 2>/dev/null
}
