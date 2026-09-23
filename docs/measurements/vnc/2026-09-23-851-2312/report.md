# 851-2312: continuous updates — notes

`validate.md` is the gate's output: PASS (tests 271 + 92, interop 5/5, bench
no regression, tophat 23/23). This change improves the target metrics, so the
run is the new baseline (`baseline-Mac16_6.json`), in the same commit.

## Result (vs the request/response baseline, 60 fps scenes, median of 3)

| case                 | updates/s before | after |                                 change |
| -------------------- | ---------------: | ----: | -------------------------------------: |
| typing / wan150      |             6.16 |  53.2 |                                   8.6× |
| scroll / wan150      |             5.79 |  54.1 |                                   9.3× |
| photo / wan150       |             1.34 |  2.06 | +54 % (now bandwidth-bound: 50 Mbit/s) |
| typing, scroll / lan |              ~61 |   ~65 |                    at the scene's pace |

CPU per update on wan150 also fell (−37 %, −42 %): fewer idle waits per
update. Input latency is unchanged (≈ one round trip: the server's echo must
still cross the link).

**Metric target** — "scroll and drag under wan150: updates/s ≥ 3× the
request/response baseline" — met (8.6–9.3×). "Update latency p95 ≤ baseline":
request → applied no longer exists for pushed updates (`RFBUpdate.latency` is
nil for them, and the benchmark omits it); input-to-update latency, the
latency that remains meaningful, is unchanged.

## What changed

- Client advertises Fence (-312) and ContinuousUpdates (-313). On the
  server's first EndOfContinuousUpdates it enables them for the whole screen
  and stops requesting; a later EndOfContinuousUpdates falls back to requests;
  a resize re-enables the new area. Servers without them keep the request loop.
- Fence requests are answered with the payload and only the ordering flags the
  client honours (it handles messages strictly in order). The client sends its
  own fence at most once a second to measure the round trip: Connection
  Details now shows "Round trip" for VNC, and the route says "· continuous".
- Reference server: both extensions (off by default, like a basic server; the
  scene server and the rig's Loopback server turn them on), `wantsUpdate`,
  `endContinuousUpdates()`; parity test covers them.

## Found along the way

- **L3:** TigerVNC confirms continuous updates, pushes the ticking `xclock`
  added to the interop desktop, and answers the client's fence (round trip
  0.3–0.4 ms on loopback). TigerVNC's brute-force blacklist tripped on the
  interop suites' parallel connections; the test server raises the threshold.
- **Rig:** the Loopback server's animated desktop only sent frames while a
  request was pending, so it froze under continuous updates; it now asks
  `wantsUpdate` (as does `vnc-server`).
- **Tophat:** the scene picker press could land before the menu opened, so
  earlier runs checked motion on the animated desktop rather than the chosen
  scene. The flow now retries and verifies the picker shows "Scene: scroll".
