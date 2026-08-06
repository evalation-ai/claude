# Evalation

The official thin client for **Evalation**, an autonomous software engineering engine.

Evalation turns a backlog of work items into shipped, reviewed, merged code, running
continuously and largely unattended. Installing this plugin connects Claude Code to
Evalation's hosted engine: **all methodology runs server-side** and is injected at runtime
only for an entitled seat. This repository contains no premium prompts, skills, orchestration,
or secrets, only the thin transport, auth, and injection glue.

## Install

1. **Install the plugin.** Get the one-line install command for your Claude Code from
   **https://evalation.ai**. It adds the Evalation marketplace and installs the thin client
   (`evalation-plugin` from the `evalation` marketplace). Once Evalation is listed on the official
   Claude Code marketplace, `/plugin install evalation-plugin@claude-plugins-official` works with
   nothing to add.

2. **Restart Claude Code from the repo you want Evalation on.** Claude Code activates a newly
   installed plugin only when it starts, so the Evalation commands below do not exist until you
   restart, and if you restart somewhere else you will have to restart again once you switch to
   your project. Start Claude Code with your target repository as the working directory, so the
   setup and commands land in the right repository the first time. Desktop app: quit it
   completely (Cmd-Q / File > Quit) and reopen it on that repo. Terminal: `cd` into the repo, exit
   the session, and run `claude` again. Opening a new window or clearing the session is not enough.

3. **Activate a seat** with `/ev-login`.

4. **Onboard this repository** with `/ev-init`. Run `/ev-account` any time to check your seat.

```
/ev-login     # OAuth flow; binds a seat token to this device (kept in the OS keychain)
/ev-init      # onboard THIS repository for autonomous software engineering
/ev-account   # show seat status and tier
```

Every new session validates the seat on start. If the seat is active, the engine injects the
tier-scoped operating instructions that drive the autonomous workflow. If it is not active, you
get a friendly onboarding prompt instead. To activate, run `/ev-login`. For more information, see our website at
https://evalation.ai.

## What this plugin does

The plugin is deliberately thin: two hooks, a few commands, and auth glue. It ships **no local
tools** and **no methodology**. Everything the engine does is delivered by the server as the
tier-scoped operating instructions injected at session start.

| Hook | Role |
|------|------|
| `SessionStart` | Validate the seat (`POST /v1/validate`), then inject the server's tier-scoped operating instructions. Fails closed: nothing is injected when the seat is not entitled. |
| `UserPromptSubmit` | Per-turn injection from the server. Quiet when there is nothing to inject. |

Usage is derived **server-side** from your authenticated calls to the hosted engine. The client
does not run a local meter and sends no per-tool telemetry (see Privacy).

## Configuration

All public, no secrets. Override via environment when needed. The client addresses **two**
endpoints: the **gateway** is the single non-secret surface (payloads, dashboard, feedback,
usage, error reports); the **entitlement / licensing** service is a separate deployable so the
token signing key stays isolated behind it and is never reachable through the gateway.

| Variable | Default | Purpose |
|----------|---------|---------|
| `EVALATION_GATEWAY_URL` | `https://gateway.evalation.ai` | Non-secret gateway base URL: payloads / dashboard / feedback / usage (point at your VPC for enterprise self-hosting). |
| `EVALATION_API_URL` | `https://api.evalation.ai` | Entitlement / licensing base URL only (the isolated signing-key service). |
| `EVALATION_CLIENT_ID` | `evalation-plugin-public` | Public client id (not a secret). |
| `EVALATION_ERROR_REPORTING` | `on` | Report this client's OWN faults back to Evalation so the team can fix the product. Set to `off` to opt out (enterprise / air-gapped). See Privacy below. |

The seat token is **never** stored in this repository or in config: it lives in the OS keychain,
written by the login flow and read at runtime.

## Signing in (`/ev-login`)

`/ev-login` runs the client sign-in helper (`bin/evalation-login`), which drives the server auth
flow and stores a **device-bound** seat token. It:

1. **Side-loads** the helpers onto a PATH directory (`${EVALATION_BIN_DIR:-$HOME/.local/bin}`) so
   a new session's hooks can find them. Ensure that directory is on your `PATH` (most shells already
   include `~/.local/bin`); if not, add it and start a new session.
2. Generates a PKCE (S256) verifier and starts a short-lived listener on a `127.0.0.1` loopback port.
   It calls `POST /v1/auth/login/start` with that loopback as the OAuth `redirect_uri`, opens the
   returned authorization URL in your browser, and the listener **captures the authorization code
   automatically** when the provider redirects back, so there is nothing to copy or paste. It then
   verifies the returned `state` (CSRF) and calls `POST /v1/auth/login/complete` (binding the token
   to this device) and stores the token.

The loopback capture uses a tiny built-in listener (`bin/evalation-loopback`, node - already present
because Claude Code runs on node). Non-interactive / headless (no browser): supply the code and the
matching loopback redirect it was obtained with via `evalation-login --code <code>` (or
`EVALATION_LOGIN_CODE`) plus `EVALATION_LOGIN_REDIRECT_URI`.

The shipped helpers (in `bin/`):

| Helper | Role |
|--------|------|
| `evalation-login` | Drive the auth flow end to end (loopback capture) and store the seat token. |
| `evalation-loopback` | The `127.0.0.1` listener that captures the OAuth redirect's code, then exits. |
| `evalation-token` | `--read` prints the stored token (empty when none), `--write` stores it (token on stdin), `--clear` removes it. |
| `evalation-device-id` | Print a stable, opaque, non-PII device fingerprint (a one-way hash; no raw serial / hostname / username). |

**Token storage is portable and never in the repository.** The raw token lives ONLY in the OS
keychain (macOS `security`; Linux `secret-tool` when present) or, where no keychain agent is
available, a `0600` fallback file at
`${EVALATION_TOKEN_STORE:-${XDG_DATA_HOME:-$HOME/.local/share}/evalation/seat-token}` (outside the
repository). It is never written to a plaintext plugin config or a log. Clear it any time with
`evalation-token --clear`; the next session then reverts to the upsell.

## Privacy

**No content ever leaves your machine through this plugin.** It never sends your prompts, tool
arguments, source code, file contents, paths, or personal data. Usage is derived server-side from
your authenticated calls, so the client runs no local meter and emits no per-tool telemetry.

**Client error reporting (default on).** When this plugin hits a fault inside *its own* client
code, it reports that fault back to Evalation so the team can fix the product. The report carries
**only structured codes**: an error class, the failing location *within the Evalation client*, the
client/plugin version, and a stack signature scrubbed of your content. It never sends your prompts,
tool arguments, file contents, paths, source code, or personal data, and it never sends faults from
*your* code. The only non-anonymised value is your organization id (so we can reach out if a fault
is serious), and that is derived server-side from your seat, never sent by the client. To opt out
entirely (for example an air-gapped or policy-restricted deployment), set
`EVALATION_ERROR_REPORTING=off`; reporting then does nothing, with no loss of functionality.

## License

Commercial. (c) Evalation. See https://evalation.ai for terms.
