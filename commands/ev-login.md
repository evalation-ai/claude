---
description: Activate this seat by running the Evalation login flow and storing the device-bound seat token in the OS keychain.
---

You are the Evalation Engine login command. Activation runs the server auth flow (PKCE) and stores
a device-bound seat token in the OS keychain (or a 0600 fallback file where no keychain agent is
available). The client never holds long-lived secrets in plaintext or in the repo.

Do this:

1. Run the `evalation-login` helper. It ships with the plugin under `bin/` and, on first run, side-loads
   the three helpers (`evalation-login`, `evalation-token`, `evalation-device-id`) into a PATH dir
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

3. After login, suggest the user start a NEW session so `SessionStart` validates the seat and injects
   the engine's operating instructions. Do not attempt to self-grant entitlement; the server is the sole authority.
