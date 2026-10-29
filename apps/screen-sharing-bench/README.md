# CodevisorBench

The screen sharing benchmark app (`CodevisorBench.app`), specified in the
[benchmark design](https://linear.app/851/document/screen-sharing-v2-benchmark-design-851-3582-0309dbbc943b)
(851-3582). It's a dev tool: not shipped, and no product target depends on it.

One binary with subcommands (`player`, `generate`, `observe`, `calibrate`, `sample`, `loopback`, and later `host`
and `viewer`).
Pure logic (barcode, stats, clock offset, network model, report) lives in the `ScreenSharingBench`
library in `packages/swift/ScreenSharing/Sources/ScreenSharingBench`.

## Layout

- `Sources/CodevisorBench` is the `CodevisorBench` executable target of `packages/swift/Package.swift`
  (linked in as `packages/swift/ScreenSharing/Sources/CodevisorBench`), so `bun run swift:test` compiles it.
- `Sources/ScreenSharingBenchScenes` is the scene library (scenes S1–S7, one Metal renderer, the Tier 1
  `BenchSceneGenerator`), linked in the same way as `packages/swift/ScreenSharing/Sources/ScreenSharingBenchScenes`.
- `Info.plist` is the bundle's plist. The bundle ID is `com.851labs.CodevisorBench`.
- `scripts/build.sh` builds a release binary into `.build/CodevisorBench.app`, embeds `WebRTC.framework` and signs it.
- `scripts/deploy.sh <ssh-host>` builds, then installs `~/Applications/CodevisorBench.app` on that Mac.
- `scripts/run.sh <ssh-host> <command> [--option value …]` runs a subcommand on that Mac's GUI session.
- `scripts/run-installed.sh <command> [--option value …]` does the same on this Mac (`run.sh` runs it over ssh).
- `scripts/calibrate-observer.sh` and `scripts/calibrate-clock.sh` are the steps of the
  `Screen Sharing Bench Calibration` workflow (`.github/workflows/screen-sharing-bench-calibration.yml`).

## Adding a subcommand

1. Add a directory under `Sources/CodevisorBench` (for example `Observe/`) with a type that conforms to
   `BenchCommand`: a `name`, a one-line `summary`, a `usage` synopsis, `init(options:)` that reads its
   options from `BenchOptions`, `presentsWindows`, and `run()`.
2. Add the type to `BenchCommands.all`.

`init(options:)` reads every option it accepts (`string`, `integer`, `flag`, `choice`); the launcher then
rejects any option nobody read. Throw `BenchUsageError` for a bad value. The process exits 0 on success,
1 on a thrown error and 64 on a usage error. A command says whether it
`presentsWindows`; the launcher parses it before the app starts and picks the `.regular` activation policy for
those (so the activation `open` gives at launch isn't lost) and `.prohibited` for the rest (so an observer
started next to the player never takes focus from it). Hide the menu bar only once active
(`BenchPresentation.hideMenuBarOnceActive`): setting `presentationOptions` from an inactive app hides the app.

## Scenes

A scene is a seeded script: `BenchScene.timeline` maps a 60 Hz tick to a version, and the version alone decides
the pixels. The player and the generator draw through the same `BenchSceneRenderer`, so a seed gives the same
pixels in both. Every frame carries the T1 luma barcode of its version in the top-left corner, above the content.

| Scene         | Versions                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------ |
| `idle-cursor` | a 2×18 pt caret blinking at 2 Hz (4 versions/s) over a static page                         |
| `typing`      | 13 pt monospace, 10 chars/s, 30 chars/s for the last 5 s of every 20                       |
| `scroll`      | a numbered document scrolling 600 pt/s, with a page-down every 5 s (60/s)                  |
| `window-drag` | an 800×600 pt window on a Lissajous path at about 1000 pt/s (60/s)                         |
| `video`       | seeded noise and moving gradients, a new frame every refresh (60/s)                        |
| `test-cards`  | text (light, dark), chroma and photo cards with corner fiducials, every 3 s                |
| `input`       | a 400×400 pt (or 16×16 pt, `--input-region small`) square that flips on every key or click |

```sh
CodevisorBench player --scene scroll --duration 60
CodevisorBench player --scene video --display virtual --resolution R2
CodevisorBench player --scene video --resolution R1 --duration 5 --hash-log /tmp/video.jsonl
CodevisorBench generate --check /tmp/video.jsonl
CodevisorBench generate --scene test-cards --first 0 --count 4 --png-dir /tmp/cards
```

The player prints one JSON report: versions/s, missed refreshes and CPU as a percentage of one core. It refuses
to run while the GUI session is locked, because macOS then never shows its frames. `--display virtual` makes a
`CGVirtualDisplay` at R1, R2 or R3 for the run. `--hash-log` hashes every drawable it presents; `generate --check`
renders the same versions offscreen and compares the hashes. `--self-input-hz` posts key events to the player
itself, to drive `input` without Accessibility.

## Observe and calibrate (851-3592)

Every time these commands print or write is mach **continuous** time in nanoseconds, the clock of the
`ScreenSharingBench` library and the clock probes. ScreenCaptureKit stamps frames with mach absolute time
(the PTS equals `SCStreamFrameInfo.displayTime` to the nanosecond), and so does the 851-3583 frame timeline;
the observer converts each PTS by adding continuous − absolute, which only grows while the Mac sleeps.
Each command prints one JSON result to stdout; a check that fails its pass criterion (C1, C2) then exits 1.

- `observe [--duration 10] [--region barcode|full] [--display <id>] [--output <file.jsonl>]` streams the
  display with ScreenCaptureKit, decodes the barcode of every complete frame and writes
  `(version, pts_ns, callback_ns)` lines after a header naming the clock (`BenchObserverLog`). Unreadable
  frames are kept, with the reason. `--region barcode` (the default) captures only the 512×32 px strip, so
  the observer costs little; the summary reports the observer's own CPU and power from `proc_pid_rusage`.
  `--barcode-x`, `--barcode-y` and `--block-size` move the strip.
- `calibrate --check c1 [--duration 30]` runs two observers on the same display, the barcode strip and the
  full display, and reports |ΔPTS| per version both saw. It passes when p95 ≤ 16.7 ms. Run it while the
  player (or `--check on-glass`) draws.
- `calibrate --check c2 --serve [--port 47592] [--duration <s>] [--idle-exit <s>]` answers clock probes
  (and stops once no probe has come for `--idle-exit` seconds); on the other Mac,
  `calibrate --check c2 --responder <ipv4> [--duration 600] [--interval 2] [--output <file.jsonl>]` sends a
  burst of 16 every interval and reports ε (largest kept round trip / 2), the drift, and two residuals: the
  windowed one (`BenchClockTrack`, each burst against a line fitted to the bursts within 30 s of it, itself
  left out) and the single line over the whole run (`linear_residual_ms`). It passes when ε ≤ 0.5 ms and the
  windowed residual ≤ 0.2 ms. Bursts slower than twice the median minimum round trip (and over 0.5 ms) are dropped and counted
  (`rejected_slow_bursts`); more than 5% dropped fails the check. Receive times are the kernel's (`SO_TIMESTAMP_MONOTONIC`), so wake-up latency
  never counts. The minis' clocks don't keep one rate for ten minutes: under CI load the single line missed
  by up to 0.87 ms while the windowed fit stayed within 0.10 ms, so convert times with `BenchClockTrack`.
- `calibrate --check c6 [--events 200] [--seed 7] [--target window|frontmost]` posts space key presses
  with `CGEventPost` 150–350 ms apart (seeded) and reports the delay to the first frame showing another
  version (`BenchInputResponses`). `window` draws its own barcode window that advances on each key through
  `ScreenSharingMetalView`, and stops early (reporting what it has, then exiting 1) if that window loses
  focus; `frontmost` leaves the frontmost app, such as `player --scene input`, to react.
- `calibrate --check on-glass [--duration 30]` presents a new barcode every refresh through
  `ScreenSharingMetalView` and its frame timeline, observes it, and reports the timeline's on-glass time,
  display-link estimate and `presentedTime` minus the observer's PTS, plus C1 for the same frames.
- `sample [--duration 10] [--interface en0] [--processes <name>,<name>…]` reports each process's CPU (% of
  one core) and power per second, summed over every process of that name alive in both samples (it looks
  them up each second), and the interface's Mbit/s each way. Processes of other users (such as
  `screensharingd`) can only be read as root.

The checks that capture the screen need **Screen Recording**, C6 needs **Accessibility**, and C2 needs
**Local Network** (without it, UDP to the other Mac fails with `EHOSTUNREACH`).

## Loopback (851-3593)

`loopback` is Tier 1: one process streams synthetic scenes through the product `ScreenSharingSender` and
`ScreenSharingReceiver` over an in-process UDP relay that emulates the network, then writes report v1. It needs
no permission grant and no GUI session (except `--onscreen`), so it runs on any CI Mac.

```sh
CodevisorBench loopback                                   # the full matrix: S1–S6 × N0–N7 at R1
CodevisorBench loopback --scenes scroll,video --networks N0,N3 --duration 20 --output report.json
CodevisorBench loopback --frames frames.jsonl --onscreen
CodevisorBench loopback --source own-window --scenes scroll --networks N0
```

- **The product, not a copy.** The sender and receiver use `ScreenSharingProductProfile` (codec order, 45 Mbit/s
  ceiling, capture box, field trials, keyframe interval, pending frames), the same as `ScreenSharingHostService`.
  The adaptive quality loop runs as in the product. The viewer renders through the product's render coordinator
  and Metal encoder into an offscreen texture (`--onscreen`: the product `ScreenSharingMetalView` in a window).
- **Sources.** `synthetic` (the default): `BenchSceneGenerator` renders each new version on a 60 Hz tick and pushes
  it to the sender's frame sink, stamped when it is pushed, so the capture stage is about 0. Like ScreenCaptureKit,
  nothing is pushed while the scene doesn't change. `own-window` (`--source own-window [--display main|virtual]`):
  the player draws the scene in a full-screen window, and the product `ScreenSharingCapture` captures that window
  (`SCShareableContent.currentProcess`), so capture is real; versions come from the barcode of each captured frame.
  It needs an unlocked GUI session.
- **Network.** The relay rewrites each side's SDP to a single host candidate on a relay socket and forwards both
  directions through `BenchRelayLink` (the T1 `BenchNetworkModel`: capacity, queue, delay, jitter, seeded
  Bernoulli or Gilbert–Elliott loss). Media and feedback get their own seeded models, so the drop pattern by packet
  index is the same on every run (`relay.media.first_losses` lists the first 16 seeded losses; drops from a full
  queue depend on the traffic and are counted in `queue_overflow`; a packet that is both is counted as an
  overflow, which no N0–N7 condition can produce because only N5 limits the queue and N5 has no random loss). Each peer socket gets its own
  mapping socket, like a NAT, so every ICE pair goes through the relay.
- **Measurement.** Each scene runs `--duration` seconds (12 by default; the matrix takes about 11 minutes) and
  the first `--warm-up` seconds (5) are left out. `e2e_ms` is capture to committed (`e2e_endpoint`), or to on-glass
  with `--onscreen`. `stages_ms` comes from the 851-3583 timeline: capture, capture queue, encode, network (the
  encoder output to decoder input span: send, the relay, receive and the jitter buffer, exact on one clock),
  decode, render queue and present. `timing_frame_check` pairs each WebRTC timing frame (`googTimingFrameInfo`,
  sampled twice a second; WebRTC keeps the slowest recent frame) with the timeline frame captured within 8 ms of it,
  and compares encode, decode and capture to decoded; it agrees when each median difference is within 5 ms.
  Drops are whole-scene counters.
- **Output.** stdout is the report JSON (`--output` also writes it); stderr has one progress line per scene and a
  Markdown summary with per-stage p50/p95. `--frames` writes one line per measured frame (version and every
  timestamp). A scene that fails (for example ICE never connects) is reported as invalid with the error, and the
  matrix goes on.
- **Results come from the workflow.** `Screen Sharing Bench Loopback`
  (`.github/workflows/screen-sharing-bench-loopback.yml`) runs `scripts/loopback.sh` on tamale as one job, so no
  CI job can overlap it: 1–3 back-to-back matrices (inputs `duration`, `scenes`, `networks`) plus the own-window
  run, uploaded as the `loopback-tamale` artifact with each matrix's wall time and the load before and after.
  Deploy the build first (`scripts/deploy.sh tamale`); the job warns when the installed app isn't from the
  dispatched commit. Runs over SSH are for development only.
- **Clocks.** The timeline stamps with mach absolute time (what ScreenCaptureKit, Core Animation and Metal use);
  the report and `frames.jsonl` use mach continuous time like the rest of the bench. Each scene reads
  continuous − absolute once and shifts every timeline timestamp by it. Durations don't change.

## Signing and permissions

The bundle is signed with the team's Developer ID Application identity (team `WH4QW9ND3J`), so its
designated requirement is the bundle ID plus the team, not a hash of the binary. Screen Recording and
Accessibility grants for `~/Applications/CodevisorBench.app` survive every rebuild and redeploy. Set
`CODEVISOR_BENCH_SIGNING_IDENTITY` to sign with another identity (grants then have to be given again).
The lab minis have no signing identity, so build on a developer Mac and deploy.

## Running on a lab Mac

```sh
apps/screen-sharing-bench/scripts/deploy.sh tamale
apps/screen-sharing-bench/scripts/run.sh tamale player --duration 5
```

`run.sh` starts the app with `open`, so it runs in the logged-in GUI session and macOS attributes
permissions to `CodevisorBench.app` rather than to `sshd`. It prints the app's stdout and stderr and exits
with its status. The minis are also CI runners: check `ps -axo command | grep Runner.Worker` first and keep
runs short.
