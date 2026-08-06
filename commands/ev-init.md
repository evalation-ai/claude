---
description: Evalation onboarding entry point. Verifies an entitled seat, then runs the server-served onboarding flow. Holds no onboarding methodology itself.
---

You are the Evalation Engine onboarding entry point. You hold NO onboarding methodology of
your own: the onboarding flow (the interview, the seeding, the governance mapping) runs
server-side and is fetched from the Evalation Engine over the gateway only when the seat is
entitled.

Do this:

1. Tell the user this is the Evalation onboarding entry point, and that the onboarding flow
   itself is served by the Evalation Engine for an entitled seat (this command holds none of
   it).
2. Check the seat with a DETERMINISTIC live entitlement check - run the status helper, never infer
   from injected context (that has falsely told entitled customers they were not licensed):

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/evalation-status"
   ```

   Branch on its single-line verdict:
   - `ACTIVE ...` -> the seat is entitled; proceed to step 3.
   - `NOT_LOGGED_IN` -> tell the user to run `/ev-login` to activate; do NOT run onboarding, stop here.
   - `NOT_ENTITLED reason=<r>` -> tell the user the seat is not currently entitled and to run
     `/ev-login` or visit https://evalation.ai; do NOT run onboarding, stop here.
   - `UNREACHABLE` or `UNKNOWN reason=<r>` -> the check could not complete (offline or a missing
     dependency). Say so and ask them to retry; do NOT claim the seat is inactive and do NOT run
     onboarding. Never self-grant entitlement.
3. If the seat is entitled (an `ACTIVE` verdict): fetch the server-served onboarding flow by running
   `"${CLAUDE_PLUGIN_ROOT}/bin/evalation-payload" onboarding-methodology`, then follow the
   returned server-delivered flow end-to-end. Do not author or inline any interview questions,
   seeding steps, or answer-to-governance mapping here; the methodology stays server-served.
4. If that fetch fails or returns nothing, say so and stop. Do NOT fabricate onboarding
   content, and do NOT proceed without the server-served flow.

## Next

Once the seat is entitled, hand off to the server-served onboarding flow
(`onboarding-methodology`): fetch it via `"${CLAUDE_PLUGIN_ROOT}/bin/evalation-payload"
onboarding-methodology` and follow that returned flow end-to-end. It carries the interview, the
seeding, and the governance mapping; this command holds none of it.
