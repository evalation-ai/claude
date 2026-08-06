---
description: Activate this seat by running the Evalation login flow and storing the device-bound seat token in the OS keychain.
---

You are the Evalation Engine login command. Activation runs the server auth flow (PKCE) and stores
a device-bound seat token in the OS keychain (or a 0600 fallback file where no keychain agent is
available). The client never holds long-lived secrets in plaintext or in the repo.

Do this:

1. Ask which identity provider they use, Google or Microsoft, before you start the flow, so a
   Microsoft customer is not forced through Google. If they have no preference, use Google. Then run
   the `evalation-login` helper with their choice as `--provider google` or `--provider microsoft`. It
   ships with the plugin under `bin/` and, on first run, side-loads the three helpers
   (`evalation-login`, `evalation-token`, `evalation-device-id`) into a PATH dir
   (`${EVALATION_BIN_DIR:-$HOME/.local/bin}`) so a new session's hooks can find them:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/evalation-login"
   ```

   It generates a PKCE verifier, calls `POST /v1/auth/login/start`, opens the returned
   `authorization_url` in your browser, collects the authorization `code`, calls
   `POST /v1/auth/login/complete` (binding the token to this device's fingerprint), and writes the
   returned seat token via `evalation-token --write`. For a non-interactive / headless run, pass the
   code directly: `evalation-login --code <code>` (or set `EVALATION_LOGIN_CODE`).

   To pick an identity provider, pass `--provider <google|microsoft>` (or set
   `EVALATION_LOGIN_PROVIDER`); the flag wins over the env var. Omit both to use the server default
   (Google), which leaves the existing Google flow unchanged. An out-of-allowlist value exits
   non-zero without contacting the server.

2. If `bin/evalation-login` is not found, tell the user to ensure the Evalation Engine plugin is
   installed (the helpers live in the plugin's `bin/`), then retry.

3. After login, the engine activates in THIS session on your next prompt: the per-turn hook does a
   one-time catch-up that validates the now-stored seat and injects the engine's operating
   instructions - no restart needed. Just send your next message and Evalation is active (run
   /ev-account to confirm). Starting a fresh session also works as a fallback. Do not attempt to
   self-grant entitlement; the server is the sole authority.

Branch on the helper's outcome (do not guess - take the exact action for the outcome you got):

- Login succeeded (helper exits 0, a seat token is stored) -> proceed to `## Next`.
- Helper not found (`bin/evalation-login` is missing) -> tell the user to ensure the Evalation
  Engine plugin is installed (the helpers live in the plugin's `bin/`), then retry this command.
- Helper exits non-zero (auth flow failed, e.g. the browser step was cancelled or the server was
  unreachable) -> report that login did not complete, do NOT store or self-grant anything, and ask
  the user to run `/ev-login` again. Never treat a failed login as active.
- Out-of-allowlist provider (an `EVALATION_LOGIN_PROVIDER` / `--provider` value outside
  `google|microsoft`; the helper exits non-zero WITHOUT contacting the server) -> tell the user to
  re-run with a supported provider (`--provider google` or `--provider microsoft`), then retry.

## Next

Run `/ev-init` to onboard this repository for autonomous software engineering.
