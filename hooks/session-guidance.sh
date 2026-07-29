#!/usr/bin/env bash
# Evalation Engine - UserPromptSubmit: always-on session-guidance norm. A static, tenant-agnostic
# anti-stall / graceful-handoff courtesy injected as suppressed context every interactive turn, so
# a long-context session hands off cleanly instead of silently stalling. UNGATED and dependency-light
# on purpose: it makes NO network call, reads NO token, touches NO entitlement state, and carries
# zero methodology - it is a universal customer-UX norm that must protect every installed session,
# including a degraded / lease-lost one (exactly when long-context stalls occur). Separate from the
# transport hook so that hook's fail-closed / quiet / output-hygiene invariants stay untouched.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$DIR/_lib.sh"

ev_have jq || exit 0   # graceful: no jq, emit nothing (mirrors the peer hooks)

NORM="Never stall on work you know how to do. When you are context-limited, do not defer in an open loop: write a brief handoff note (the plan, the files, the current state, and what is left), hand the user a short ready-to-paste continuation prompt, and ask them to run /compact and paste it back. A clean handoff is the last resort; an open \"should I?\" loop is not an option."

jq -n --arg ctx "$NORM" '{continue:true, additionalContext:$ctx, suppressOutput:true}'
exit 0
