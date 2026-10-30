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
- `scripts/build-pinned.sh <directory>` builds and copies the bundle there; CI runs it at the job's commit.
- `scripts/deploy.sh <ssh-host> [--force]` builds, then installs `~/Applications/CodevisorBench.app` on that Mac (it refuses
  to replace an app signed by another team; see Signing and permissions).
- `scripts/run.sh <ssh-host> <command> [--option value …]` runs a subcommand on that Mac's GUI session.
- `scripts/run-installed.sh <command> [--option value …]` does the same on this Mac (`run.sh` runs it over ssh). It
  opens `CODEVISOR_BENCH_APP` when that is set, and `~/Applications/CodevisorBench.app` otherwise.
- `scripts/calibrate-observer.sh` and `scripts/calibrate-clock.sh` are the steps of the
  `Screen Sharing Bench Calibration` workflow (`.github/workflows/screen-sharing-bench-calibration.yml`).

## Adding a subcommand

1. Add a directory under `Sources/CodevisorBench` (for example `Observe/`) with a type that conforms to
   `BenchCommand`: a `name`, a one-line `summary`, a `usage` synopsis, `init(options:)` that reads its
   options from `BenchOptions`, `presentsWindows`, and `run()`.
2. Add the type to `BenchCommands.all`.

Every command runs inside a `.userInitiated`, `.latencyCritical` `ProcessInfo` activity, so macOS doesn't App Nap
the windowless ones (the observers, samplers, clock probes and `share`) while they measure.

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
  `screensharingd`) report CPU only (see Tier 2 below).

The checks that capture the screen need **Screen Recording**, C6 needs **Accessibility**, and C2 needs
**Local Network** (without it, UDP to the other Mac fails with `EHOSTUNREACH`).

## Loopback (851-3593)

`loopback` is Tier 1: one process streams synthetic scenes through the product `ScreenSharingSender` and
`ScreenSharingReceiver` over an in-process UDP relay that emulates the network, then writes report v1. It needs
no permission grant and no GUI session (except `--onscreen` and `--source own-window`, which capture the screen and
so need the session unlocked and a Screen Recording grant), so it runs on any CI Mac.

```sh
CodevisorBench loopback                                   # the full matrix: S1–S6 × N0–N7 at R1
CodevisorBench loopback --scenes scroll,video --networks N0,N3 --duration 30 --warm-up 10 --repetitions 3 \
  --output report.json
CodevisorBench loopback --frames frames.jsonl --onscreen
CodevisorBench loopback --source own-window --scenes scroll --networks N0
```

- **The product, not a copy.** The sender and receiver use `ScreenSharingProductProfile` (codec order, 45 Mbit/s
  ceiling, capture box, field trials, keyframe interval, pending frames), the same as `ScreenSharingHostService`.
  The adaptive quality loop runs as in the product. The viewer renders through the product's render coordinator
  and Metal encoder into an offscreen texture (`--onscreen`: the product `ScreenSharingMetalView` in a window).
- **Sources.** `synthetic` (the default): `BenchSceneGenerator` renders the next versions ahead, and a strict 60 Hz
  `DispatchSourceTimer` on a user-interactive queue pushes each new version to the sender's frame sink, stamped when
  it is pushed, so the capture stage is about 0 and frames are 16.67 ms apart within ±0.06 ms, like ScreenCaptureKit's
  vsync-stamped frames. (A Swift `sleep` on the cooperative pool wakes up to 8 ms late, and WebRTC's jitter estimate
  follows that noise.) Like ScreenCaptureKit, nothing is pushed while the scene doesn't change. `own-window` (`--source own-window [--display main|virtual]`):
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
  the first `--warm-up` seconds (5) are left out. `--repetitions <n>` runs the whole list n times, interleaved (every
  cell once, then every cell again), and each result carries its `repetition`; consumers take the median per cell
  (`BenchCellSummary`). The report's `run.method` records duration, warm-up, repetitions and the plan (`--plan`). `e2e_ms` is capture to committed (`e2e_endpoint`), or to on-glass
  with `--onscreen`. `stages_ms` comes from the 851-3583 timeline: capture, capture queue, encode, network (the
  encoder output to decoder input span: send, the relay, receive and the jitter buffer, exact on one clock),
  decode, render queue and present. The relay also notes when it delivers the last RTP packet of each video frame
  (`BenchFrameArrivals`; SRTP leaves the RTP header readable), and the barcode tap gives each decoded frame's RTP
  timestamp, so the network stage splits into `send` (encoder output → frame complete: pacing, the relay and the
  emulated network) and `decode_queue` (frame complete → decoder input: the jitter buffer and playout delay).
  `e2e_outside_jitter_buffer_ms` is e2e without that wait. `timing_frame_check` pairs each WebRTC timing frame (`googTimingFrameInfo`,
  sampled twice a second; WebRTC keeps the slowest recent frame) with the timeline frame captured within 8 ms of it,
  and compares encode, decode and capture to decoded; it agrees when each median difference is within 5 ms.
  Drops are whole-scene counters.
- **Output.** stdout is the report JSON (`--output` also writes it); stderr has one progress line per scene and a
  Markdown summary with per-stage p50/p95. `--frames` writes one line per measured frame (version and every
  timestamp). A scene that fails (for example ICE never connects) is reported as invalid with the error, and the
  matrix goes on.
- **Results come from the workflow.** `Screen Sharing Bench` (below) runs Tier 1 on tamale. Runs over SSH are for
  development only.
- **Clocks.** The timeline stamps with mach absolute time (what ScreenCaptureKit, Core Animation and Metal use);
  the report and `frames.jsonl` use mach continuous time like the rest of the bench. Each scene reads
  continuous − absolute once and shifts every timeline timestamp by it. Durations don't change.

## Tier 2: Codevisor vs Apple High Performance (851-3595)

Numbers come only from the `Screen Sharing Bench Tier 2` workflow
(`.github/workflows/screen-sharing-bench-tier2.yml`, `workflow_dispatch`). A runner takes one job at a time,
so no CI job overlaps a run. Each job builds and signs CodevisorBench at the run's commit
(`build-screen-sharing-bench`, as Tier 1 does), and the measuring jobs then install that build at
`~/Applications/CodevisorBench.app` (`scripts/install-granted.sh`) and run it from there: the minis refused Screen
Recording and Accessibility to the same build run from elsewhere, and the grants are for the CI signing team's app
(see Signing and permissions). The build stays
installed after the run, so the installed app is that of the last Tier 2 (or own-window Tier 1) dispatch. So `gh workflow run
screen-sharing-bench-tier2.yml --ref <branch>` needs no deploy. Keep a dispatch under about 30 minutes, since the
minis are the only ARM64 CI runners: run one scene per dispatch (`scenes` defaults to `scroll`; about 25 minutes with the floor
and 3 repetitions of the three systems, after the build and the C5 wait for a quiet machine, up to 10 minutes). C4 runs only when
video is among the scenes. A plan longer than 45 minutes of runs fails at once. `network` picks N0 (no shaping) or N3: the viewer job
loads dummynet rules into the `com.apple/codevisor-bench` pf anchor (croissant's sudoers allows `dnctl` and `pfctl`),
1 ms of delay and 1% random loss each way for all of tamale's addresses (no rate limit: the wired link is already
1 Gbit/s, and a dummynet rate limit runs on croissant's 10 ms kernel tick, which added 6–7 ms each way) (its IPv4 address and every
address its Bonjour name resolves to, so Apple HP and WebRTC are shaped whichever path they pick), except the clock
probes (UDP 47592), which keep C2 a clean clock reference. Before each run it probes tamale's second responder (UDP
47596, shaped) for 5 s and records the round trip and loss that took effect (`network-check.json`, the runs table's
"Network check"). The anchor and pipes are flushed at the start and on exit. Runs over ssh are for
development only.

The `host` job (tamale, `scripts/tier2-host.sh`) and the `viewer` job (croissant, `scripts/tier2-viewer.sh`)
walk the same plan (`scripts/tier2-lib.sh`): for each scene the null-sharing floor, then per repetition
(`repetitions`, default 3, `duration` seconds each) Apple HP, Codevisor on a virtual display and Codevisor on
the physical display, and with `c4` S5 once per primary system with the host observer off. The nightly bench
workflow calls this one through `workflow_call` with the same defaults, so its Tier 2 runs include C4.

Apple HP has no mode that shares the host's physical display: its Display Type offers only "1 Virtual Display"
and "2 Virtual Displays", and with one virtual display the host's main display becomes "Screen Sharing Virtual
Display" at 1920×1080 pt @2x (3840×2160 px). So the primary rows compare like for like at `R1x2`: Apple HP on
its virtual display, and Codevisor on a 1920×1080 @2x `CGVirtualDisplay` that `share --virtual-display R1x2`
creates (the player and host observer draw on and watch it by display ID; the product then scales it to its
2560×1440 capture box, as it would for any such display). Codevisor on the physical 1920×1080 @1x display is an
extra `R1` row. On croissant both `R1x2` streams are shown at half size, so the viewer observer reads 8 px
barcode blocks. The floor runs on the physical display, so "above floor" for `R1x2` rows uses the R1 floor. The host job serves `rendezvous` and the clock probes; the viewer job connects for up to
30 minutes, and the two first agree that they run the same CodevisorBench build. Before each run, the two jobs meet at named barriers: `start` (both preflights pass), `system`
(the host's `share` is listening), `ready` (the viewer shows Apple HP full screen, the Codevisor stream or the
floor window), `measure` (the host's preflight during the run) and `done`. Measurement starts at `measure`:
the viewer's observer, clock probes and sampler, the host's observer and sampler, and 3 s later the
player. A failed status at a barrier skips the run on both Macs. The `report` job merges both artifacts and
runs `tier2-report`, which writes `report.json` and `summary.md` (also the job summary).

- `rendezvous --serve` holds each named barrier until both parties arrive, then tells both every party's
  status; `rendezvous --host <ipv4> --barrier <name> --party host|viewer [--status <text>]` exits 1 unless
  every status is `ok`.
- `preflight [--allow-screen-sharing-from <address or Bonjour name>,…]` prints load, thermal state, CI jobs,
  the displays and every established `:5900` peer, and fails when the session is locked, a peer isn't
  allowed, or the main display is `Screen Sharing Virtual Display` with no allowed peer. Apple HP is itself a
  `:5900` session from the viewer, so the host allows the viewer's IPv4 address and Bonjour name (resolved to
  all its addresses, link-local scopes ignored).
- `share [--port 47593] [--duration <s>] [--ready-file <path>] [--stop-file <path>]` is the Codevisor host: it waits for one viewer
  on TCP, answers its offer with a `ScreenSharingSender` built from `ScreenSharingProductProfile`, captures the
  main display once connected and runs `ScreenSharingQualityLoop`, as the host service does.
- `view --source codevisor --host <ipv4>` is the Codevisor viewer: a `ScreenSharingReceiver` with the
  product's `ScreenSharingVideoSurface` in a full-screen window. It reports the frame timeline summary and
  the selected candidate pair. `view --source null [--port 47594]` is the floor (C3): it draws the barcode of
  each version that `observe --relay <viewer ipv4>:47594` on the host sends the moment the host observer
  first sees it (`BenchVersionMessage`, 20 bytes), through the same surface.
- `apple-hp [--host tamales-Mac-Mini.local]` opens `vnc://<host>` in Screen Sharing.app (the saved Bonjour
  entry `tamales-Mac-Mini.local`, never an IP), makes the session window full screen through Accessibility and
  parks the pointer at the bottom of the screen: a pointer at the top edge reveals the full-screen menu bar over
  the barcode, which then never changes. It keeps Screen Sharing frontmost (counting `focus_losses`; any makes the
  run invalid), reports whether its full-screen window was on screen and the checked menu items, and quits Screen Sharing.app at the end. Tier 2
  launches every windowless command with `open -g` (`CODEVISOR_BENCH_BACKGROUND=1`) so none takes focus.
- `sample --output <file.jsonl>` also writes one `BenchUsageSecond` line a second. A process name of the
  form `CodevisorBench:share` matches only the bench processes running that subcommand. It finds processes in one
  `/bin/ps -axo pid,time,comm` listing a second (`ps` is setuid, so it sees root's `screensharingd`). Processes
  that `proc_pid_rusage` can't read without root get their CPU time from that listing (10 ms resolution) and
  no power; a system with any such process in any second reports no power.

Image age is `BenchSharingAnalysis`: the viewer observer's first PTS of each version minus the host
observer's first PTS mapped to the viewer's clock by `BenchClockTrack` (±30 s windows). Apple HP runs count only when `apple-hp` selected High Performance in Screen Sharing's
"Select Screen Sharing Type:" sheet, read the selection back and clicked Continue (`chose_high_performance`). The window starts
5 s after both observers first read a barcode and ends 2 s before either stops. Versions the host showed and
the viewer never did are skipped versions. Updates/s, gaps and freezes (typing, scroll, window drag and video
only) come from the viewer's versions in the window; judder is the viewer's gap p95 minus the host's. CPU is
the per-second sum of the system's processes (Apple HP: `screensharingd`, `ScreensharingAgent` and
`Screen Sharing`; Codevisor: the `share` and `view` processes; both: `VTEncoderXPCService` and
`VTDecoderXPCService`), and bitrate is croissant's en0 receive rate. A run is invalid when it didn't come
from the workflow (no `github_run_id`), C2 fails (ε over 0.5 ms or residual over 0.2 ms), another CI job ran,
a preflight found a problem, or over 1% of the viewer's frames were unreadable (except video). `BenchSystemComparison` compares the medians of the valid repetitions. It is a difference when the medians differ by
more than the noise band, the wider of the two systems' min–max spreads, or when each system has at least 3 valid
repetitions and the gap between their ranges is wider than the tighter system's spread, and in either case only when
the medians differ by at least 2% of the larger one; the verdict table names the rule that fired.

## Benchmark workflow, results and gate (851-3594)

`Screen Sharing Bench` (`.github/workflows/screen-sharing-bench.yml`) is the one workflow for numbers. Every job
that measures builds CodevisorBench at its own commit and signs it with the Developer ID in the repository secrets
(`APPLE_CODESIGN_IDENTITY`, team `C4M7D4G7LG`; `.github/actions/build-screen-sharing-bench`,
`scripts/signing-keychain.sh`), into `$RUNNER_TEMP`, and runs it through `CODEVISOR_BENCH_APP`. Synthetic Tier 1
needs no permission grant and never touches `~/Applications/CodevisorBench.app`. Own-window Tier 1 and Tier 2 need
Screen Recording and Accessibility, so they install their build there first (`scripts/install-granted.sh`, see
Tier 2): the minis refused those to a build run from elsewhere, and the grants must be for the CI signing team's app
(see Signing and permissions).

- **Nightly** at 03:00 Pacific (two UTC crons; the `plan` job keeps the one that is 03:00 in Los Angeles), and
  `workflow_dispatch`. The `tier1` job on tamale (concurrency group `screen-sharing-bench`) waits for a quiet machine
  (C5), then runs `scripts/tier1.sh nightly`: the `core` report (S1–S6 at N0 and N3, 3 interleaved repetitions of
  30 s with 10 s warm-up, about 20 min), the `gate` report (exactly the PR gate's run: S2, S3 and S5 at N0 and N3,
  about 10 min) and the `matrix` report (N1, N2 and N4–N7, 1 repetition, about 20 min). Each report records its plan
  in `run.method.plan`, and a baseline only uses nightlies of the same plan: the same cell measured among other
  scenes differs, for example typing's N3 p95 is about 35 ms in `core` and about 52 ms in the gate's run. Reports
  from before plans existed match no plan, so a new plan's baseline starts empty (`-f plans=gate` seeds it).
  A dispatch with `scenes` or `networks` set runs one `custom` report instead (`source` picks `own-window`, which
  captures the screen: that run installs the build over `~/Applications/CodevisorBench.app` with
  `scripts/install-granted.sh`, because macOS grants Screen Recording to that path only).
- **`benchmark-results`.** On `main`, `scripts/publish.sh` commits each report to the orphan branch
  `benchmark-results` as `runs/YYYY/MM/DD/<run id>-tier1.json`, with its chart (`.svg`), and appends a line to
  `index.jsonl` (`BenchIndexEntry`: the run, its path and one `BenchCellSummary` per cell). `main` never holds
  results. Scheduled runs and dispatches with `kind: nightly` are recorded as `nightly`, the only runs a baseline
  reads; other dispatches are `adhoc`.
- **Summary.** `summarize` writes the job summary: the per-cell table (median over repetitions, the range, the
  change against the median of the last 7 nightlies with the same method), the stage table, the C5 result and the
  chart. GitHub strips inline SVG from summaries, so the chart (a stacked per-stage bar and the nightly e2e p50 trend
  per cell) is the committed `.svg`, linked at that commit.
- **PR gate.** A pull request touching `packages/swift/ScreenSharing`, the CodevisorCoreMac screen sharing sources,
  this app or the workflow runs the `gate` job on tamale in its own per-PR concurrency group (so it can't cancel a
  queued nightly or Tier 2 run; the runner takes one job at a time). The `gate` job measures the `gate` plan twice (about
  20 min), and the `gate` subcommand compares both runs with the nightly `gate` baseline using the design §4.2
  rules (`BenchRegressionGate`): a cell fails only when both runs cross a threshold. At N0, latency (p50 up more
  than max(15%, 3 ms), p95 up more than max(20%, 5 ms)) is judged on e2e outside the jitter buffer once the runs and
  every baseline nightly split it out, and the jitter buffer gets its own rule (p50 up more than max(100%, 40 ms));
  N3 is judged on whole e2e, where jitter-buffer growth under loss is a regression. At N0, WebRTC's
  jitter estimate for scroll, video and test cards sits at the product's 80 ms playout cap, and each process lands
  either at the cap or well below it, so whole e2e there can move by 30% between unchanged runs. The summary also
  says how long the gate waited for tamale and which bench runs were active meanwhile.
  Closing or merging the pull request starts a `stop-gate` job on a GitHub-hosted runner in that group, which
  cancels a gate still queued or running for it.
- **Calibration and Tier 2** run after Tier 1 through `workflow_call` when the dispatch inputs ask for them, or every
  night once the repository variable `SCREEN_SHARING_BENCH_NIGHTLY_TIER2` is `true`. Calibration still uses the installed
  app; Tier 2 builds its own.

`preflight --quiet` is C5. It waits at least `--settle` seconds (60) and up to `--settle-limit` (300) for the
1-minute load to drop to 2.0 and Spotlight to stop indexing (a fresh build sets it off), then fails on a thermal state other than nominal, Spotlight indexing (`mds_stores` or
`mdworker*` above 5% CPU), Time Machine or `softwareupdate` running, en0 not up at 1000baseT, other regular apps
open (Finder aside), anyone screen sharing into the Mac, or a locked session (`--allow-locked` skips that check for
offscreen Tier 1). It also fails when load and Spotlight never stayed quiet for 3 samples in a row before the
limit (`reached_settle_limit`). `loopback` records Spotlight indexing in `environment.host.spotlight_busy`. The
`plans` dispatch input (empty: `core,gate,matrix`) applies to the nightly plan only; a dispatch with `scenes` or
`networks` set runs one custom report and warns if `plans` was given.

```sh
gh workflow run screen-sharing-bench.yml -f kind=nightly                    # the nightly plan, recorded as a baseline
gh workflow run screen-sharing-bench.yml -f kind=nightly -f plans=gate      # only the gate's baseline (about 12 min)
gh workflow run screen-sharing-bench.yml -f scenes=scroll -f networks=N0    # an ad hoc run
CodevisorBench gate --index index.jsonl --first first.json --second second.json
CodevisorBench record --report report.json --results <benchmark-results checkout>
```

## Encoder lab (851-3767)

`encode-lab` encodes scene frames offscreen with VideoToolbox, one config at a time, and reports what each costs.
It needs no permission grant and no GUI session.

```sh
CodevisorBench encode-lab --scenes scroll,typing --duration 8 --warm-up 2 \
  --configs "name=product;name=native,size=3840x2160;name=tiles,size=3840x2160,tiles=4,skip=1" \
  --output encode-lab.json --markdown encode-lab.md
```

- **Source.** `BenchSceneGenerator` renders each new version at `--resolution` (R1x2, 3840×2160, by default), scales
  it to the config's `size` with `VTPixelTransferSession`, and converts it to the encoder's input format (BGRA for
  `hevc444`, as the product feeds it; 4:2:0 for the others). A 60 Hz timer submits each version on its tick, so the
  encoder sees the scene's real cadence; idle ticks submit nothing, like ScreenCaptureKit.
- **Configs.** `--configs` takes `;`-separated `key=value` lists; every key defaults to the product encoder
  (`ScreenSharingProductProfile`: HEVC 4:4:4, standard rate control, speed over quality, 45 Mbit/s, 2560×1440;
  `hevc` and `h264` default to low-latency rate control without speed priority, the product's fallbacks). A `preset`
  or `cq` keeps its own bitrate and speed unless `mbps` or `speed` is given too.
  Keys: `name`, `engine` (`vt`, or `vcp` below), `codec` (`hevc444`, `hevc`, `h264`), `rc` (`standard`, `ll`), `mbps`
  (or `none`), `size`, `tiles` (horizontal stripes, one session each, the bitrate split evenly), `skip` (encode only the
  tiles whose pixels changed), `ltr`, `yuv`, `speed`, `mfd` (`MaxFrameDelayCount`), `qpmax`, `qpmin`, `drl` (`<mbps>@<seconds>`),
  `preset` (`vc`, `speed`, `balanced`, `quality`), `cq` (`ConstantQualityFactor`, macOS 27), `aq`, `ackms` (the
  simulated round trip before a reference token is acknowledged, 33 ms by default), `refine` (after each change,
  resubmit the unchanged frame up to N times, every other tick, so the encoder can sharpen it) and `vcpin`.
- **`engine=vcp`** opens Apple's real-time encoder, VideoProcessing's private `VCPCompressionSession` with
  `Usage = 42` (851-3766), loaded with `dlopen`. It takes whole frames in `vcpin` (`444f` by default, Apple's capture
  format; it picks Main 4:4:4 only when the source attributes are 4:4:4 and not lossless-compressed), splits them into
  `tiles` (1–4) itself, skips unchanged tiles, and labels each output with `TileID`. Every reference token it asks for
  (`RequireAcknowledgementToken`) is acknowledged after `ackms`, and the refresh is a `ForceLTRRefresh`. One decoder
  decodes all its tiles, as Apple's viewer does.
- **Per cell** (scene × config), after `--warm-up`: encode time (submit to the last tile's output), how long frame
  preparation and the submit call took, Mbit/s, frame sizes, the chroma format the encoder actually wrote (read from
  `hvcC`), the first frame's size, and a refresh halfway through: a forced keyframe, or with `ltr=1` a
  `ForceLTRRefresh` with tokens acknowledged after a simulated 33 ms round trip, on the middle tile only.
- **Quality.** A second pass decodes every frame in order with the hardware decoder and, on `--quality-samples`
  evenly spaced frames, compares the picture a viewer would show (skipped tiles keep their last image) with the
  source converted to 4:4:4 (BT.709, video range): PSNR of Y and of Cb/Cr (4:2:0 chroma upsampled by nearest
  neighbour) and SSIM of Y (Wang 2004, 11×11 Gaussian, σ 1.5). A single-tile config smaller than the canvas is also
  upscaled back and compared with the native frame (`native`), so downscaling counts against it; tiled configs get
  no native score. `engine=vcp` with `444f` input is compared in full range, the range it encodes.
- **CI.** Dispatch `Screen Sharing Bench` with `encode_lab` set to the configs (and `encode_lab_options` for the
  rest); that runs only the `encode-lab` job on tamale and puts the table in the job summary.

## Signing and permissions

A bundle signed with a Developer ID Application identity has a designated requirement of the bundle ID plus that
identity's team, not a hash of the binary, so Screen Recording and Accessibility grants for
`~/Applications/CodevisorBench.app` survive every rebuild signed by the same team. There are two teams in play, and
macOS treats their builds as different apps:

- CI signs with the repository secret `APPLE_CODESIGN_IDENTITY` (team `C4M7D4G7LG`), imported into a temporary
  keychain for the build; the lab minis have no signing identity of their own. The grants on the minis must be for
  this team's app for in-job builds to capture the screen.
- `scripts/build.sh` on a developer Mac picks the team `WH4QW9ND3J` identity by default (set
  `CODEVISOR_BENCH_SIGNING_IDENTITY` to choose another).

macOS keeps one Screen Recording and one Accessibility grant per bundle ID (`com.851labs.CodevisorBench`), for one
team. Granting a WH4QW9ND3J build replaces the C4M7D4G7LG grant, after which every CI job that captures the screen
(own-window Tier 1, Tier 2, calibration through the installed app) is refused. So `scripts/deploy.sh` refuses to
replace an installed app signed by another team unless given `--force`. To see which team an installed app
belongs to, run `codesign -dv ~/Applications/CodevisorBench.app 2>&1 | grep TeamIdentifier` on the mini.

## Running on a lab Mac

```sh
apps/screen-sharing-bench/scripts/deploy.sh tamale
apps/screen-sharing-bench/scripts/run.sh tamale player --duration 5
```

`run.sh` starts the app with `open`, so it runs in the logged-in GUI session and macOS attributes
permissions to `CodevisorBench.app` rather than to `sshd`. It prints the app's stdout and stderr and exits
with its status. The minis are also CI runners: check `ps -axo command | grep Runner.Worker` first and keep
runs short.
