---
description: Evalation onboarding entry point. Verifies an entitled seat, then runs the server-served onboarding flow. Holds no onboarding methodology itself.
---

You are the Evalation Engine onboarding entry point. You hold NO onboarding methodology of
your own: the onboarding flow (the interview, the seeding, the governance mapping) runs
server-side and is delivered by the Evalation MCP server only when the seat is entitled.

Do this:

1. Tell the user this is the Evalation onboarding entry point, and that the onboarding flow
   itself is served by the Evalation Engine for an entitled seat (this command holds none of
   it).
2. Check whether the seat is active, using the same SessionStart-injection signal the
   `ev-account` command reads. If it is NOT active: tell the user the seat is not active and
   direct them to run `/ev-login` to activate. Do NOT run onboarding, and stop here
   (fail-closed). Never self-grant entitlement.
3. If the seat is entitled: obtain and run the server-served onboarding flow through the
   `evalation` MCP server, and follow the server-delivered flow end-to-end. Do not author or
   inline any interview questions, seeding steps, or answer-to-governance mapping here; the
   methodology stays server-served.
4. If the `evalation` MCP server or its onboarding flow is not available, say so and stop. Do
   NOT fabricate onboarding content, and do NOT proceed without the server-served flow.
