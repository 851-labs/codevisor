# 851-2371 — baseline: Codevisor native path vs Apple Screen Sharing High Performance

Host tuftlord (MacBook Pro M1 Pro, macOS 27, 3024×1964). Viewer this Mac
(M4 Max). Both on the same 1 Gbit/s wired LAN. `bun run vnc:frame-clock
--host-ssh tuftlord@…` with the host page on wall-clock frames
(`?clock=epoch`), 45 s per run, each viewer measured on its own:

- our native path: the rig's "tuftlord · High Performance" entry, i.e. the
  product's viewer against the Codevisor app 0.1.102 on tuftlord;
- Apple Screen Sharing, High Performance mode (UDP 5900–5902).

The two Macs' clocks agree within 0.5 ms (± 1.5 ms, measured over one SSH
connection), so **image age** is absolute: when a frame first appeared on
this Mac minus when tuftlord's page drew it (includes the host's display
latency).

## Result

|                                                                       | test   | updates/s | gap p50 / p95 ms | image age p50 / p95 ms | Mbit/s |
| --------------------------------------------------------------------- | ------ | --------: | ---------------: | ---------------------: | -----: |
| **Apple HP** (4K virtual display)                                     | video  |  **48.3** |          18 / 36 |          **158 / 228** |     54 |
|                                                                       | scroll |  **45.8** |          18 / 36 |          **150 / 161** |     21 |
|                                                                       | type   |  **44.6** |          18 / 37 |          **140 / 157** |      – |
| **Codevisor native** (display scaled to ≤1080p, 12 Mbit/s cap), run 1 | video  |      34.4 |          34 / 38 |              164 / 205 |    9.6 |
|                                                                       | scroll |      35.0 |          34 / 37 |              190 / 218 |   10.1 |
|                                                                       | type   |      34.8 |          34 / 38 |              173 / 197 |    0.9 |
| run 2                                                                 | video  |      32.5 |          34 / 54 |              114 / 164 |   10.7 |
|                                                                       | scroll |      32.6 |          34 / 53 |              131 / 150 |   10.3 |
|                                                                       | type   |      30.0 |          35 / 55 |              145 / 164 |    0.6 |

**Noise:** our runs differ by up to 10% in updates/s and 40 ms in image age.
tuftlord was loaded by other work during the first runs (load average
15–25 falling to ~4). An earlier native video run under that load gave
378 / 437 ms and is excluded. Apple's runs were made under more load than
our run 2, so its numbers are, if anything, pessimistic: a conservative
target. A second Apple run failed to calibrate (the session froze after
reconnecting) and is not included.

## What it says

- **Frame rate is the clearest gap:** we deliver ~30–35 updates/s with a
  flat 34 ms gap (a 30 fps ceiling: the host's adaptive quality is at its
  30 fps step or capture is paced at 30), Apple ~45–48 (gap 18 ms, ~60 fps
  with drops).
- **Image age is comparable at p50** (114–190 ms vs 140–158), slightly
  worse at p95 on video, while Apple streams a **4K** virtual display at
  5–6× our bitrate and we send ≤1080p. So on pixels per millisecond, Apple
  is far ahead.
- **Bitrate:** we're pinned near our 12 Mbit/s cap (~10); Apple uses
  21–54 Mbit/s as content needs.

## Targets for the next tickets

| metric                           |       today (native) |                  target (Apple HP) |
| -------------------------------- | -------------------: | ---------------------------------: |
| updates/s, video / scroll / type |                32–35 |          ≥ 45 (goal 58+ at 60 fps) |
| gap p95                          |             38–55 ms |                            ≤ 36 ms |
| image age p50 / p95, video       | 114–164 / 164–205 ms |             ≤ 158 / 228 ms (at 4K) |
| resolution                       |       ≤ 1080p scaled | 4K / pixel-exact (virtual display) |

## Harness changes (this ticket)

- Host page `?clock=epoch`: frames count wall-clock 1/60 s; a black margin
  above the strip keeps Safari's tinted toolbar from merging with it.
- `screen-sharing-rig frame-clock --host-offset-ms`: absolute image age per
  viewer (`FrameClockTimeline.imageAges`), and each viewer's receive
  bitrate (nettop) where the traffic is the app's own (Apple HP's UDP
  belongs to a helper; read it from the 5901 flow).
- `bun run vnc:frame-clock --host-ssh USER@HOST`: measures the clock offset
  over one SSH connection (`clockOffset`, shortest round trip).
