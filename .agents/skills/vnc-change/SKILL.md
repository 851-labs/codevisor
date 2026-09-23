---
name: vnc-change
description: Validate every VNC change with the four-layer test method and the vnc-bench benchmark before calling it done. Use when working on the VNC client or server path (RFB/VNC code in packages/swift/ScreenSharing, RFBWebSocketTransport, the server's VNC socket route, scripts/vnc-desktop.sh, RFBLoopbackServer), on any Linear issue under 851-2308 "Great VNC experience", or when asked to pick up or finish VNC backlog work.
---

# VNC change

Read `docs/plans/vnc-validation.md` first; it is the rulebook. This skill is
the checklist for applying it.

## Pick the work

1. List the issues under 851-2308 in Linear (project codevisor). An issue is
   ready when every issue blocking it is Done. Take the highest-priority ready
   issue; scaffolding (851-2323…851-2328, 851-2309, 851-2310) comes first
   because every feature issue is blocked by 851-2328.
2. Move it to In Progress. Check it has acceptance criteria and a metric
   target; if not, write them into the issue before coding.
3. If the issue needs a product decision (e.g. 851-2317, what ⌘ sends), stop
   and ask.

## Do the work

1. Write the failing test first: L1 (bytes → pixels, malformed input) or L2
   (client against `RFBLoopbackServer`). Follow the `deterministic-tests`
   skill: no sleeps, real clocks or fixed ports; use the shaping transport's
   test clock for network behaviour.
2. Implement the client side and the reference server's side together. The
   parity test must stay green.
3. If only a real server shows the behaviour, record it with the wire
   recorder and add the L1 fixture.

## Prove it

1. `bun run vnc:validate --issue 851-XXXX` (VNC suites, `vnc:interop`,
   `vnc-bench` against the baseline, `vnc:tophat`). It must exit 0 and writes
   `docs/measurements/vnc/<date>-<issue>/validate.md`. Needs OrbStack running
   (`orbctl start`) and Accessibility permission for the terminal.
2. Check the report: acceptance criteria met, metric target met, no metric
   outside the issue's scope worse than the noise band.
3. For UI-visible changes also follow the `tophat` skill. Launch the rig in
   the background and capture only its window; never capture the rest of the
   user's screen.

## Land it

1. Commit with the report summary in the body and a
   `Validation: docs/measurements/vnc/<date>-<issue>/validate.md` trailer.
   Update the baseline (`--save-baseline`) only when this issue improves a
   metric, in the same commit. Land it as a pull request and merge it.
2. Post the summary (and screenshots) on the Linear issue, move it to Done,
   and go back to "Pick the work".

## Stop and ask when

- a gate fails for a reason outside the issue, or an unrelated metric
  regresses;
- L3 can't run (no container runtime or image) or Contabo is unreachable and
  the target needs it;
- the target can only be met by weakening a test, threshold or baseline;
- the issue needs a product decision.
