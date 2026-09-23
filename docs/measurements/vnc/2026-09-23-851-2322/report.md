# 851-2322: Contabo desktop tuned for streaming — notes

`validate.md` is the gate's output: PASS (tests 317 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Contabo tophat
(`bun run vnc:tophat --machines contabo`): 7/7, with a new check that the
video isn't blank. The desktop is on screen 1–2 s after connecting.

## What changed

- `scripts/vnc-desktop.sh`:
  - turns xfwm4's compositor off (xfconf, persisted);
  - documents the reviewed Xvnc settings, left at their defaults: FrameRate 60,
    CompareFB 2, DeferUpdate 1 ms;
  - documents that `GEOMETRY` is only the starting size (the viewer resizes the
    desktop, 851-2314);
  - installs xdotool;
  - is now safe to rerun on a desktop in use: Xvnc and codevisor-server
    restart only when their configuration changed.
- `scripts/vnc-desktop-sample.sh` + `screen-sharing-rig vnc-sample`: measure a
  real desktop through an SSH tunnel. An idle window, then a terminal dragged
  at ~28 moves/s, then 40 keystrokes timed from send to their echo.
- `vnc:tophat --machines contabo` checks that the video has content
  (`rig-ax colours`). It used to pass with a black frame captured before the
  first picture arrived.

## Contabo re-provisioned

Backup of the previous config: `/root/codevisor-backup-851-2322` on the box
(xfwm4.xml, the vncserver unit, ~/.vnc). Rerunning the script did not
restart Xvnc or codevisor-server (unchanged `ActiveEnterTimestamp`s). To
revert the compositor:
`DISPLAY=:1 xfconf-query -c xfwm4 -p /general/use_compositing -s true`.

## Measurements (TigerVNC 1.13.1, 1227 × 754, lossless; `samples/`)

| run           | drag updates/s | drag Mbit/s | bytes/update | echo p50 | echo p95 | RTT p50 |
| ------------- | -------------: | ----------: | -----------: | -------: | -------: | ------: |
| before 1      |            6.5 |        0.75 |        14535 |   198 ms |   209 ms |  166 ms |
| before 2      |           23.0 |        2.11 |        11448 |   199 ms |   228 ms |  196 ms |
| before 3      |            7.5 |        0.86 |        14248 |   200 ms |   298 ms |  172 ms |
| after 1       |            7.4 |        0.81 |        13845 |   205 ms |   316 ms |  188 ms |
| after 2       |            2.7 |        0.43 |        19664 |   201 ms |   431 ms |  828 ms |
| after 3       |            3.7 |        0.49 |        16782 |   202 ms |   293 ms |  320 ms |
| median before |            7.5 |        0.86 |        14248 |   199 ms |   228 ms |  172 ms |
| median after  |            3.7 |        0.49 |        16782 |   202 ms |   316 ms |  320 ms |

**The metric target is not met.** Turning the compositor off didn't
measurably improve update latency or bytes. The after runs are worse, but
their round trip was worse too (320 vs 172 ms median, one run at 828 ms): the
public route's jitter dominates. Echo p50 (≈ RTT + 30 ms) didn't move.

What limits the drag is TigerVNC's congestion control, not the desktop. At
~14 KB per update the server sends about one update per round trip (6.5/s at
166 ms) while the desktop produces ~28 moves/s. Its window starts at 16 KB and
evidently doesn't grow on this route. That belongs to a follow-up (Tight
compression level from the client; checking why the window stays small
through codevisor-server), not to desktop tuning.

The compositor stays off as decided: it saves server CPU and removes shadow
repaints, and no measurement regressed beyond the route's noise.
