# OAuth credential ferry — refresh-token reuse spike (Phase 21, Part 1)

Status: findings

This document records the Phase 21 spike: what happens when two machines hold the
same OAuth refresh-token family for the subscription-backed harnesses (Claude Code
via claude.ai, Codex via ChatGPT). It fixes the design constraints the rest of
Phase 21 must honor. No behavior ships from this document.

## Method

The destructive experiment — copy a live login to a second machine, let both
refresh, observe — was deliberately NOT run against real accounts: the failure
mode under investigation is precisely how it would invalidate the user's own
logins. Instead the verdict is drawn from two production reference
implementations that manage exactly these token families for a living
(`.repos/claude-swap`, `.repos/codex-multi-auth`), plus the harnesses' own
documented behavior. Their evidence is conclusive and consistent.

## Findings

### Anthropic (claude.ai)

- Refresh ROTATES the refresh token on every refresh. `claude-swap`'s refresh
  grant adopts a new `refresh_token` from every response
  (`oauth.py: try_refresh_oauth_credentials`).
- A superseded refresh token DIES. `claude-swap` quarantines accounts whose
  refresh token has stopped working and warns that "a stale export can carry an
  already-superseded token" — i.e. the previous token is dead the moment the
  next refresh lands.
- The harness binary refreshes AUTONOMOUSLY on use: "Claude Code refreshes the
  token on your next message." Codevisor does not control when it happens.

### OpenAI (ChatGPT / Codex)

- Rotation PLUS active reuse detection. Codex surfaces an explicit
  `refresh_token_reused` error meaning "the token pair rotated in another
  context — re-login the affected account"
  (`codex-multi-auth/docs/troubleshooting.md`). Using an old token after
  rotation invalidates the family.
- `codex-multi-auth` builds cross-process refresh LEASES
  (`~/.codex/multi-auth/refresh-leases/`) whose sole job is to dedupe
  concurrent refresh, and an in-process old→new `tokenRotationMap` so racing
  callers converge on one refresh. Even so it explicitly "does not coordinate
  across separate agent processes" and never attempts cross-MACHINE sharing.

### Verdict

Both providers: **strictly single-owner refresh. Neither tolerates a naive
shared family** — two machines each running the harness (which self-refreshes)
guarantees the loser gets a dead token. There is no usable grace window to lean
on. Notably, both reference tools independently converged on single-machine
designs; neither ferries a live login to a second simultaneously-active machine.

## Consequence for Phase 21

The naive "replicate the credential file to every machine" ferry is UNSAFE for
OAuth subscriptions. Two designs remain:

1. **Refresh-owner ferry (2a).** Exactly one machine refreshes and republishes
   the rotated family through the config plane; mirrors adopt verbatim and never
   refresh. This is the MCP-OAuth pattern — but harder here, because the harness
   BINARY refreshes autonomously on any machine it runs on. Viable only if mirror
   -side refresh can be reliably suppressed (advisory-lock cooperation like
   claude-swap, plus owner refreshing proactively ahead of expiry and propagating
   within seconds). Any propagation gap or offline mirror that gets used = a
   second refresher = family death. Fragile and per-harness.

2. **Relayed per-machine re-auth (2b).** The login does not travel; the sign-in
   FLOW travels. A machine that needs a subscription login shows "needs sign-in"
   in readiness; the user taps it from any device and the browser/device-code
   flow (already relayed for Codex) runs against that machine. Robust,
   provider-agnostic, no family-invalidation risk.

**Recommendation:** make **2b the default** for subscription OAuth on both
providers — it is safe, simple, and matches how the reference tools already
treat the constraint. Keep 2a as an opt-in, harness-specific optimization only
where mirror refresh can be provably suppressed. Static API-key credentials
continue via the Phase 20 ferry unchanged; Phase 21's remaining work is
broadening that static source list and wiring the relayed re-auth surface.
