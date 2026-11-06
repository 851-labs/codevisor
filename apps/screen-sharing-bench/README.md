# CodevisorBench

The screen sharing benchmark app (`CodevisorBench.app`), specified in the
[benchmark design](https://linear.app/851/document/screen-sharing-v2-benchmark-design-851-3582-0309dbbc943b)
(851-3582). It's a dev tool: not shipped, and no product target depends on it.

One binary with subcommands (`player`, `generate`, `observe`, `calibrate`, `sample`, `loopback`, `share`, `view`,
`inject` and more; `CodevisorBench` with no arguments lists them).
Pure logic (barcode, stats, clock offset, network model, report) lives in the `ScreenSharingBench`
library in `packages/swift/ScreenSharing/Sources/ScreenSharingBench`.

## Layout

- `Sources/CodevisorBench` is the `CodevisorBench` executable target of `packages/swift/Package.swift`
  (linked in as `packages/swift/ScreenSharing/Sources/CodevisorBench`), so `bun run swift:test` compiles it.
- `Sources/ScreenSharingBenchScenes` is the scene library (scenes S1–S7, one Metal renderer, the Tier 1
  `BenchSceneGenerator`), linked in the same way as `packages/swift/ScreenSharing/Sources/ScreenSharingBenchScenes`.
- `Info.plist` is the bundle's plist. The bundle ID is `com.851labs.CodevisorBench`.
- `scripts/build.sh` builds a release binary into `.build/CodevisorBench.app` and signs it.
- `scripts/build-pinned.sh <directory>` builds and copies the bundle there; CI runs it at the job's commit.
- `scripts/deploy.sh <ssh-host> [--force]` builds, then installs `~/Applications/CodevisorBench.app` on that Mac (it refuses
  to replace an app signed by another team; see Signing and permissions).
- `scripts/run.sh <ssh-host> <command> [--option value …]` runs a subcommand on that Mac's GUI session.
- `scripts/run-installed.sh <command> [--option value …]` does the same on this Mac (`run.sh` runs it over ssh). It
  opens `CODEVISOR_BENCH_APP` when that is set, and `~/Applications/CodevisorBench.app` otherwise.
- `scripts/calibrate-observer.sh` and `scripts/calibrate-clock.sh` are the steps of the
  `Bench screen sharing calibration` workflow (`.github/workflows/bench-screen-sharing-calibration.yml`).

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
pixels in both. Every frame carries the T1 luma barcode of its version in the top-left corner, above the content. With `player --bottom-barcode` (Tier 2 passes it in every scene but test cards and input; 851-3976), every scene but test cards and input also carries it in the bottom-left corner, so a viewer that shows the tiles of an update at different times can be seen: the top barcode lands in the top tile and the bottom one in the bottom tile. Nothing else draws it, so the encode lab, the loopback and every scene without the flag dirty only what they did before.

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
  `--barcode-x`, `--barcode-y` and `--block-size` move the strip; `--barcode-anchor bottom` measures `--barcode-y` up from the display's bottom edge instead, for the bottom barcode. With `--region full`,
  `--stills <dir> --stills-versions <v>,<v>…` also writes, for each listed version, its last frame within 2 s of its
  first as `<dir>/<version>.png`, captured in sRGB (T8 below). The 2 s cut keeps a viewer that updates in tiles from
  saving a frame where the next card has started to arrive under the old barcode.
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

`loopback` is Tier 1: one process streams synthetic scenes through engine v2's `ScreenSharingV2Host` and
`ScreenSharingV2Viewer` (over `codevisor-media` on an iroh connection) through an in-process UDP relay that emulates
the network, then writes report v1. It needs no permission grant and no GUI session (except `--onscreen` and
`--source own-window`, which capture the screen and so need the session unlocked and a Screen Recording grant), so it
runs on any CI Mac.

```sh
CodevisorBench loopback                                   # the full matrix: S1–S6 × N0–N7 at R1
CodevisorBench loopback --scenes scroll,video --networks N0,N3 --duration 30 --warm-up 10 --repetitions 3 \
  --encoder vt --output report.json
CodevisorBench loopback --frames frames.jsonl --onscreen
CodevisorBench loopback --source own-window --scenes scroll --networks N0
```

- **The product, not a copy.** The host and viewer use `ScreenSharingV2Profile` (codec, 45 Mbit/s ceiling, capture
  box, tiles, refinement), the same as the product's engine v2. No quality loop runs: engine v2 follows the
  transport's encoder ceiling itself. The viewer renders through the product's render coordinator and Metal encoder
  into an offscreen texture (`--onscreen`: the product `ScreenSharingMetalView` in a window).
- **Encoders.** `--encoder vcp` (the default since 851-4048, as in the product) uses the VCP encoder (851-3819) and
  records its results as `codevisor-v2-vcp`; `--encoder vt` records `codevisor-v2`, so a cell's baseline never mixes
  the two encoders. Tier 1's baseline plans (`core-v2`, `gate-v2`, `matrix-v2`, and the PR gate) pass `--encoder vt`, so
  their `codevisor-v2` series and baselines stay VideoToolbox; a `custom` dispatch takes the workflow's `encoder`
  input (`vt` by default, to match them; `vcp` for `codevisor-v2-vcp`).
- **Sources.** `synthetic` (the default): `BenchSceneGenerator` renders the next versions ahead, and a strict 60 Hz
  `DispatchSourceTimer` on a user-interactive queue pushes each new version to the host's frame sink, stamped when
  it is pushed, so the capture stage is about 0 and frames are 16.67 ms apart within ±0.06 ms, like ScreenCaptureKit's
  vsync-stamped frames. (A Swift `sleep` on the cooperative pool wakes up to 8 ms late.) Like ScreenCaptureKit,
  nothing is pushed while the scene doesn't change. `own-window` (`--source own-window [--display main|virtual]`):
  the player draws the scene in a full-screen window, and the product `ScreenSharingCapture` captures that window
  (`SCShareableContent.currentProcess`), so capture is real; versions come from the barcode of each captured frame.
  It needs an unlocked GUI session.
- **Network.** Both endpoints bind with the `direct-pinned` path policy and the viewer dials the relay's host-facing
  socket as the host's only address, so every datagram crosses the emulated network. `direct-pinned` keeps the path a
  connection was opened on (one remote per endpoint; if that path closes it waits for it rather than taking another):
  with `direct-only`, iroh's QUIC NAT traversal learns the host's own addresses and moves to the direct loopback path
  within the first round trip (`codevisor-net`'s `pinned_path` test). A run is invalid when the relay carried under
  half the media bytes the host's session sent ("media went around the relay"). The relay forwards both directions
  through `BenchRelayLink` (the T1 `BenchNetworkModel`: capacity, queue, delay, jitter, seeded Bernoulli or
  Gilbert–Elliott loss). Media and feedback get their own seeded models, so the drop pattern by packet index is the
  same on every run (`relay.media.first_losses` lists the first 16 seeded losses; drops from a full queue depend on
  the traffic and are counted in `queue_overflow`; a packet that is both is counted as an overflow, which no N0–N7
  condition can produce because only N5 limits the queue and N5 has no random loss). Each peer socket gets its own
  mapping socket, like a NAT.
- **Measurement.** Each scene runs `--duration` seconds (12 by default; the matrix takes about 11 minutes) and
  the first `--warm-up` seconds (5) are left out. `--repetitions <n>` runs the whole list n times, interleaved (every
  cell once, then every cell again), and each result carries its `repetition`; consumers take the median per cell
  (`BenchCellSummary`). The report's `run.method` records duration, warm-up, repetitions and the plan (`--plan`).
  `e2e_ms` is capture to committed (`e2e_endpoint`), or to on-glass with `--onscreen`. `stages_ms` comes from the
  851-3583 timeline: capture, capture queue (the admission stage: capture → encode submit), encode, network (the
  encoder output to decoder input span, exact on one clock), decode, render queue (the compose stage) and present.
  There is no jitter buffer, so the frame-complete time is the decoder input time, `decode_queue` is 0, and the
  gate's outside-the-jitter-buffer rule judges whole e2e. A bench-side transport tap (`V2MediaTap`) wraps each side's
  `ScreenSharingIrohMediaTransport` and notes when each frame was handed to `send_frame`, its frame ack (`queued` and
  `sending`) and its receipt (`assembling`, how it was recovered), keyed by stream and frame number, and joined to
  the viewer's timeline by source timestamp (the first presentation of each source frame; an LTR refresh of an
  already shown capture is not a new sample). `stages_ms.media` splits the network stage: `hand_off` (encoder output
  → `send_frame`), `queue` (→ first packet out), `send` (first → last packet out), `network` (last packet out → frame
  complete), `assemble` (first packet in → frame complete, overlapping `send`) and `recover` (the `assemble` of
  frames that NACK or FEC completed). The result's `media` holds the session's counters for the whole scene: frames
  sent and given up, tiles skipped, captures replaced before encode (dropped by admission) and admission deferrals,
  NACKs, retransmissions, parity packets, FEC and NACK repairs, LTR refreshes, LTR refreshes the encoder answered with
  a keyframe instead (`ltr_refresh_keyframes`, the host's `encodedLTRRefreshKeyFrames`; the Tier 2 v2 table's "LTR
  refreshes as keyframes"), keyframes, and the capacity estimate and round trip at the end. Drops are whole-scene counters.
- **Output.** stdout is the report JSON (`--output` also writes it); stderr has one progress line per scene and a
  Markdown summary with per-stage p50/p95. `--frames` writes one line per measured frame (version and every
  timestamp). A scene that fails (for example the connection never opens) is reported as invalid with the error, and
  the matrix goes on.
- **Engine v1.** Engine v1 (WebRTC) left the bench in 851-3826, with its `codevisor` and `codevisor-r1x2` systems and
  the `core`, `gate` and `matrix` plans (now `core-v2`, `gate-v2` and `matrix-v2`). `codevisor` stays a
  `BenchSystem` so older reports and the results branch's index still decode, and `tier2-report` still reads an
  older Tier 2 run directory whose `meta.json` says `"system": "codevisor"` (with `"engine": "v2"` it counts as
  `codevisor-v2`, as it did).
- **Results come from the workflow.** `Bench screen sharing` (below) runs Tier 1 on tamale. Runs over SSH are for
  development only.
- **Clocks.** The timeline stamps with mach absolute time (what ScreenCaptureKit, Core Animation and Metal use);
  the report and `frames.jsonl` use mach continuous time like the rest of the bench. Each scene reads
  continuous − absolute once and shifts every timeline timestamp by it. Durations don't change.

## Tier 2: Codevisor vs Apple High Performance (851-3595)

Numbers come only from the `Bench screen sharing tier 2` workflow
(`.github/workflows/bench-screen-sharing-tier2.yml`, `workflow_dispatch`). A runner takes one job at a time,
so no CI job overlaps a run. Each job builds and signs CodevisorBench at the run's commit
(`build-screen-sharing-bench`, as Tier 1 does), and the measuring jobs then install that build at
`~/Applications/CodevisorBench.app` (`scripts/install-granted.sh`) and run it from there: the minis refused Screen
Recording and Accessibility to the same build run from elsewhere, and the grants are for the CI signing team's app
(see Signing and permissions). The build stays
installed after the run, so the installed app is that of the last Tier 2 (or own-window Tier 1) dispatch. So `gh workflow run
bench-screen-sharing-tier2.yml --ref <branch>` needs no deploy. Keep a dispatch under about 30 minutes, since the
minis are the only ARM64 CI runners for this repository and lil.tech: a plan whose runs take longer than 30 minutes
(each run's duration plus 30 s; runs of 30 to 50 s took 21 to 24 s more in November 2026) fails at once. `scenes`
defaults to `scroll`: about 18 minutes with the floor and 3 repetitions of the two default systems, after the build and
the C5 wait for a quiet machine, up to 10 minutes. C4 runs only when video is among the scenes. `network` picks N0 (no
shaping), N3 or N6 for the whole dispatch, and a scene can name its own (`scenes: input,scroll@N3,typing@N3`): the
viewer job loads dummynet rules into the `com.apple/codevisor-bench` pf anchor before the first run on a network and
reloads them when the network changes (croissant's sudoers allows `dnctl` and `pfctl`), and its runs are named
`NN-scroll-N3-<system>-<rep>`.
N3 is 1 ms of delay and 1% random loss each way (no rate limit: the wired link is already 1 Gbit/s, and a dummynet
rate limit runs on croissant's 10 ms kernel tick, which added 6–7 ms each way). tamale's addresses are a pf table
(`<codevisor-bench-host>`), not an address list in each rule: pf expands a list into one rule per address without
removing duplicates (tamale's IPv4 address and the same address resolved from its Bonjour name), and dummynet
re-injects a packet at the rule after the one that matched, so before 851-3749 every packet went through the pipe once
per copy. N3 then realized a 6.7–7.5 ms round trip with about 6% of probes lost (Tier 2 runs 41595120437,
41640331873 and 41683010503). Through the table, croissant's network lab (lab run 42279069653, below) measured N3 at a
3.16 ms p50 round trip against 0.64 ms unshaped (dummynet's 1 ms delay holds a packet about 1.25 ms), and N6 at 53.4 ms. N6 (851-3822) is 25 ms of delay, 0.1%
loss and 50 Mbit/s each way, with a 500 KB queue (about 80 ms at 50 Mbit/s, so the link queues rather than drops like
N6's unlimited queue); dummynet has no jitter, so it lacks Tier 1 N6's 5 ms, and the rate limit's 10 ms tick makes
the link release in bursts. The rules cover all of tamale's addresses (its IPv4 address and every
address its Bonjour name resolves to, so Apple HP and Codevisor are shaped whichever path they pick), except the clock
probes (UDP 47592), which keep C2 a clean clock reference. Before each run it probes tamale's second responder (UDP
47596, shaped) for 10 s (160 probes) and records the round trip and loss that took effect (`network-check.json`, the
runs table's "Network check", and each result's `network_check`). The summary's "Network as realized" table pools
them per network against the spec: the unshaped round trip from the same runs' clock probes plus twice the delay, and
a round-trip loss of 1 − (1 − loss each way)² (1.99% for N3). The anchor and pipes are flushed at the start and on exit. Runs over ssh are for
development only.

The minis are organization runners shared by this repository's CI and 851-labs/lil.tech's (`check` jobs),
on `codevisor-macos-arm64`. On a busy day they are about 90% busy and CI jobs wait 40 to 78 minutes for one. So the
two Tier 2 jobs queue at once like any CI job, keep their place in the queue, and pair up when they start
(`scripts/tier2-pair.sh`, which reads the run's job states through the GitHub API with the `actions: read` token).
Each job first checks out the repository and waits for its peer job to be in progress before it builds
anything. Seeing the peer in progress on polls 60 s apart counts as paired: a peer that has just given up its
runner has finished by then. A job whose peer is still queued after 10 minutes skips its other steps and gives
up its runner, and its `host-retry` or `viewer-retry` job joins the queue again at once. The other job then pairs
with that retry. A retry waits up to an hour for its peer and then fails instead of giving up again. A job also
fails at once if its peer ended without running the bench. `report` merges whichever jobs ran the bench (a retry
uploads `tier2-tamale-retry` or `tier2-croissant-retry`), and runs only when both sides did. The hello rendezvous below starts only once both
jobs are paired.

Why this rule: replaying the minis' jobs from both repositories over 3 November 2026, 16:00 to 02:00 UTC, for a
dispatch every 5 minutes:

| Rule                                                            | Starved over 3 h | Time to pair, median / p90 | Mini held idle, median / p90 |
| --------------------------------------------------------------- | ---------------- | -------------------------- | ---------------------------- |
| Wait until both minis are idle and no CI is queued              | 75%              | 11 / 24 min                | 0 / 0 min                    |
| Wait until no CI is queued                                      | 61%              | 16 / 43 min                | 0 / 17 min                   |
| Wait until no CI queued before the dispatch is still waiting    | 0%               | 40 / 77 min                | 4 / 19 min                   |
| Queue at once, hold 10 min, rejoin once, then hold up to 60 min | 0%               | 19 / 41 min                | 5 / 17 min                   |

The last rule rejoins the queue in 29% of dispatches. The replay assumes the runners serve queued jobs in order,
and it doesn't model the delay a held mini adds to CI.

The `host` job (tamale, `scripts/tier2-host.sh`) and the `viewer` job (croissant, `scripts/tier2-viewer.sh`)
walk the same plan (`scripts/tier2-lib.sh`): for each scene the null-sharing floor, then per repetition
(`repetitions`, default 3, `duration` seconds each) each system in `systems` (Apple HP and `codevisor-v2-vcp` by
default), and with `c4` S5 once per system with the host observer off. The nightly bench
workflow calls this one twice through `workflow_call` (see Benchmark workflow), with a `label` that names each call's
artifacts (`tier2-<label>-tamale`, `tier2-<label>-croissant`, `tier2-<label>-report`) and a `bench-artifact` that
makes every job run the night's one build instead of building its own (`.github/actions/fetch-screen-sharing-bench`).
`input-events` (200 by default) sets the input scene's presses and clicks of each kind, which must fit the run.

Apple HP has no mode that shares the host's physical display: its Display Type offers only "1 Virtual Display"
and "2 Virtual Displays", and with one virtual display the host's main display becomes "Screen Sharing Virtual
Display" at 1920×1080 pt @2x (3840×2160 px). So the rows compare like for like at `R1x2`: Apple HP on
its virtual display, and Codevisor on a 1920×1080 @2x `CGVirtualDisplay` that `share --virtual-display R1x2`
creates (the player and host observer draw on and watch it by display ID; engine v2 captures it at 3840×2160 in
four tiles). On croissant's main display both `R1x2` streams are shown at half size, so the viewer observer reads
8 px barcode blocks. The floor runs on the physical display, so "above floor" for `R1x2` rows uses the R1 floor. The host job serves `rendezvous` and the clock probes; the viewer job connects for up to
30 minutes, and the two first agree that they run the same CodevisorBench build. Before each run, the two jobs meet at named barriers: `start` (both preflights pass), `system`
(the host's `share` is listening), `ready` (the viewer shows Apple HP full screen, the Codevisor stream or the
floor window), `measure` (the host's preflight during the run) and `done`. Measurement starts at `measure`:
the viewer's observer, clock probes and sampler, the host's observer and sampler, and 3 s later the
player. A failed status at a barrier skips the run on both Macs. The `report` job merges both artifacts and
runs `tier2-report`, which writes `report.json` and `summary.md` (also the job summary). In every scene but test cards and input, the player draws the bottom barcode and each side runs a second observer on it (`host-bottom.jsonl`, `viewer-bottom.jsonl`). The summary's top-and-bottom table gives the image age at both barcodes and the share of viewer frames whose two barcodes show different versions (torn frames: at every frame either observer records inside the run's window, the latest version each has seen, with readings less than 2 ms apart taken as one frame; a region stream records a frame only when its own strip changed, so frames aren't paired one to one). The host draws both barcodes in one frame, so its torn share is a check on the method and should be 0. The bottom image age uses the top's window.

- `rendezvous --serve` holds each named barrier until both parties arrive, then tells both every party's
  status; `rendezvous --host <ipv4> --barrier <name> --party host|viewer [--status <text>]` exits 1 unless
  every status is `ok`.
- `preflight [--allow-screen-sharing-from <address or Bonjour name>,…]` prints load, thermal state, CI jobs,
  the displays and every established `:5900` peer, and fails when the session is locked, a peer isn't
  allowed, or the main display is `Screen Sharing Virtual Display` with no allowed peer. Apple HP is itself a
  `:5900` session from the viewer, so the host allows the viewer's IPv4 address and Bonjour name (resolved to
  all its addresses, link-local scopes ignored).
- `share [--port 47593] [--duration <s>] [--ready-file <path>] [--stop-file <path>] [--encoder vt|vcp]` is the
  Codevisor host and `view --source codevisor --host <ipv4> [--present arrival|display-link] [--tiles on|off]` the
  Codevisor viewer, both engine v2 (`ScreenSharingV2`). The host waits for one viewer on TCP, binds an iroh endpoint
  (direct paths only, ALPN `codevisor/screen/1`), sends its address over that signaling connection and captures the
  shared display; the viewer adds the host's signaling IPv4 to each port, connects and shows the stream with the
  product's surface in a full-screen window. The viewer reports the timeline, the media session's counters and the
  QUIC round trip as `selected_candidates`, so N3 runs prove their shaped path. The workflow's `present` (arrival)
  and `systems` (`apple-hp,codevisor-v2-vcp`) inputs pick them, and `meta.json` records `system` and
  `presentation`. Both Codevisor systems run on the same R1x2 virtual display: `codevisor-v2-vcp` with the VCP
  encoder (`share --encoder vcp`, 851-3819) and `codevisor-v2` with VideoToolbox (`--encoder vt`), so
  `systems: apple-hp,codevisor-v2,codevisor-v2-vcp` compares Apple HP with v2's public and private encoders,
  alternating within each repetition; the `vcp-fail-after` input (seconds, 0 by default) forces a VCP failure that
  far into each of its runs (`--vcp-fail-after`), so the run shows the VideoToolbox fallback. The v2 table has a row
  per Codevisor system and encode p95.
- The viewer's `system.json` keeps its frame records (the timeline's last 1,800) (`frames`: source timestamp, viewer
  decode, render and on-glass times, and stages), and every render commit of a new frame (`commits`, the last 4,096:
  commit time, update id, the capture's source timestamp when the frame has one, refinements don't, and
  `presented_ns` when Metal reports the drawable on glass; on the headless minis it never does, 851-4039), with
  `continuous_minus_absolute_ns` (sampled when the viewer starts) to put commit times on the observers' clock. The
  product records commits only when `ScreenSharingMetrics.commits.isRecording` is on, which only the bench viewer
  sets. A commit's source timestamp names the player version the host observer saw then, and the viewer observer's
  first sighting of that version gives the commit's real time to the screen, including frames that never get a
  presentation callback. `share.json` also lists every capture's display time, callback time, dirty-rect count and
  whether it touched the barcode corner (`captures`, up to 6,000), so a run can tell whether a change reached the
  encoder late or left it late (851-3975). The host captures without the cursor, as the product does once the viewer
  subscribes to its cursor stream (851-3823) and as Apple HP's stream leaves it out; with it, T8 charged v2 alone for
  the cursor (Tier 2 run 41695143473: one cursor block was ~97% of VCP's remaining luma error).
- `view --source null [--port 47594]` is the floor (C3): it draws the barcode of
  each version that `observe --relay <viewer ipv4>:47594` on the host sends the moment the host observer
  first sees it (`BenchVersionMessage`, 20 bytes), through the same surface.
  `view` and `apple-hp` take `--virtual-display R1x2`, which shows the window on a virtual display of that size
  (T8 below), and write `<state> display <id>` to the ready file.
- `apple-hp [--host tamales-Mac-Mini.local]` opens `vnc://<host>` in Screen Sharing.app (the saved Bonjour
  entry `tamales-Mac-Mini.local`, never an IP), makes the session window full screen through Accessibility and
  parks the pointer at the bottom of the screen: a pointer at the top edge reveals the full-screen menu bar over
  the barcode, which then never changes. It keeps Screen Sharing frontmost (counting `focus_losses`; any makes the
  run invalid), reports whether its full-screen window was on screen and the checked menu items, and quits Screen Sharing.app at the end. Tier 2
  launches every windowless command with `open -g` (`CODEVISOR_BENCH_BACKGROUND=1`) so none takes focus.
- `inject --output <events.jsonl> [--keys 200] [--clicks 200] [--seed 7] [--start-delay <s>] [--duration <s>]
[--display <id>]` posts space presses and left clicks (at the centre of the main display, or of `--display`, which
  Tier 2 sets to the viewer's display with `viewer-display: R1x2`) with `CGEventPost`, in a seeded order, 150–350 ms
  apart (seeded, as C6), to whatever app is frontmost, and logs each event's kind and the mach continuous time just
  before it was posted (`BenchInputEvent`). It prints how many of each it posted and which app was frontmost for how
  many events. It refuses a schedule longer than `--duration`, and needs **Accessibility**.
- `view --control` (Codevisor, with `--present arrival`, the presentation with an input surface) takes the control lease like the product's Control mode once
  the first frame is shown, and marks itself ready only once granted: it sends a request, then a heartbeat every second,
  and forwards the product `ScreenSharingVideoSurface`'s input (its keyboard event tap and mouse handling) through
  `ScreenSharingInputForwarder`. `share` always serves control with the product `ScreenSharingHostControl` and
  `ScreenSharingInputInjector` on the shared display (deadline checked every 250 ms, Accessibility required on the
  host). Both results carry a `control` summary (grants, denials, revocations, forwarded and injected events). Engine
  v2 has no input path yet (E8
  puts control on QUIC streams), so the bench carries the same `ScreenSharingControlMessage`s as JSON lines on its own
  TCP signaling connection (`SignalingControlChannel`, `TCP_NODELAY`, on the same wired path as the media), which stays
  open for the whole session. That is bench-only: it measures v2's picture path behind a stand-in input transport, not
  E8's.
- `apple-hp --control` makes sure Screen Sharing is in Control mode before it marks itself ready: the View menu offers
  "Switch to Observe Mode" while controlling and "Switch to Control Mode" while observing, so it presses the latter if
  present and fails if Screen Sharing still observes. It reports `control_mode` and `mode_at_end`.
- `sample --output <file.jsonl>` also writes one `BenchUsageSecond` line a second. A process name of the
  form `CodevisorBench:share` matches only the bench processes running that subcommand. It finds processes in one
  `/bin/ps -axo pid,time,comm` listing a second (`ps` is setuid, so it sees root's `screensharingd`). Processes
  that `proc_pid_rusage` can't read without root get their CPU time from that listing (10 ms resolution) and
  no power; a system with any such process in any second reports no power.

**S7, input to photon (851-3596).** `scenes: input` runs the `input` scene: the host's player flips its square on
every key press or click it receives. In each run the viewer starts `inject` 8 s after measurement starts (200 space
presses and 200 clicks by default, `TIER2_INPUT_EVENTS`; about 100 s, so dispatch with `duration: 115`), with Apple HP
in Control mode (`apple-hp --control`) and Codevisor holding the control lease (`view --control`). Only the viewer's
clock is used: `BenchInputToPhoton` pairs each posted event with the viewer observer's first frame showing another
version (`BenchInputResponses`), for all events and per kind. The floor of the input scene is C6 instead of C3: the
viewer runs `player --scene input` locally and the same `inject`, with nothing shared (the host sits that run out). Its unreadable fraction counts only the frames from the first event to 1 s after the last, so the player's window closing after the events doesn't count. A
run is invalid when no event was posted, any event went to another frontmost app than Screen Sharing or CodevisorBench,
Codevisor never held or lost the lease, Screen Sharing was in Observe mode, or no event changed the picture. The report
adds `i2p_ms` to each result, `local_i2p_ms` (the pooled floor) to the calibration, `i2p_ms.p50` and `i2p_ms.p95` to the
verdicts, and an "Input to photon" table: events, answered, p50/p95/max, key and click p50, p50 and p95 above the floor,
and p50 above Apple HP's on the same network against M3's target (at most 8 ms). Apple HP is always R1x2, so a
one-dispatch S7 that fits 30 minutes is `scenes: input, duration: 115, systems: apple-hp,codevisor,codevisor-v2`.

Each input run also records when every event passed each stage (851-3951), so the time from the viewer's post to the
host's picture splits into stages: the viewer's `control.forwarded` in `system.json` (when the surface handed each
event to the forwarder, on the viewer's clock), the host's `control.injected` in `share.json` (just before `ScreenSharingInputInjector` posted it, on the host's
clock) and the host player's `inputs` in `player.json` (when its window received each key or mouse down, with
`eventAgeMs`). Map the host's times to the viewer's with the run's `clock.jsonl`.

**Warm-up.** Apple HP's first run after the floor was slow every time in T7 (I2P 149 ms against about 98, image age 75
against 25), so when Apple HP is among the systems each dispatch first runs one unmeasured Apple HP warm-up
(`NN-<scene>-apple-hp-warm-up`) after the first scene's floor: `TIER2_WARM_UP_S` seconds (30 by default; 0 turns it
off), with as many input events as fit. The viewer writes no `meta.json` for it, so the report leaves it out.

The target table's host and viewer CPU count the system's own processes (below); its "system CPU" columns are each
Mac's `all_processes` total (the sample's `all_processes.cpu_pct`, each result's `system_cpu_pct`), observers and
sampler included, so a system's work in a process the lists miss still shows.

**Display phase (851-4092).** Each run's display phase (`display_phase_ms`, the runs table's "Display phase ms") is the
time from a host refresh to the next viewer refresh: the circular mean of each observer's frame timestamps modulo
1/60 s, the host's mapped to the viewer's clock by the run's clock track, viewer minus host. Both minis' frame
timestamps sit on a 1/60 s grid of their own clock, so the phase is fixed within a dispatch (it moved about 0.02 ms a
run in run 42020214479) and drifts between dispatches; the host can't choose it. A run whose timestamps don't hold a
steady 60 Hz phase (mean resultant length under 0.9) has none. The summary opens with the dispatch's phase and has a
"Display phase and image-age parity" table: window-drag, scroll and typing at N0, each v2 system against Apple HP in
the same dispatch against M3 (p50 at most HP + 8 ms, p95 at most HP + 17 ms, medians of valid repetitions). Before
#1022 v2 lost at phases of 9.3–10.1 ms and every dispatch since landed at 12.2–14.6 ms, so when the phase is below
12 ms a miss is flagged as a regression in the summary's first line.

Image age is `BenchSharingAnalysis`: the viewer observer's first PTS of each version minus the host
observer's first PTS mapped to the viewer's clock by `BenchClockTrack` (±30 s windows). Apple HP runs count only when `apple-hp` selected High Performance in Screen Sharing's
"Select Screen Sharing Type:" sheet, read the selection back and clicked Continue (`chose_high_performance`). The window starts
5 s after both observers first read a barcode and ends 2 s before either stops. Versions the host showed and
the viewer never did are skipped versions. Updates/s, gaps and freezes (typing, scroll, window drag and video
only) come from the viewer's versions in the window; judder is the viewer's gap p95 minus the host's. CPU is
the per-second sum of the system's processes (Apple HP: `screensharingd`, `ScreensharingAgent`, `avconferenced` and
`Screen Sharing`; Codevisor: the `share` and `view` processes; both: `VTEncoderXPCService` and
`VTDecoderXPCService`), and bitrate is croissant's en0 receive rate. The host's usage lines also record `WindowServer` and `replayd`, which neither system's figure counts. When `sudo -n` may run `/usr/bin/powermetrics`, each host run also writes `host-power.txt`, a second-by-second `powermetrics --samplers cpu_power,gpu_power` log of the whole package, as a cross-check that doesn't depend on which processes a system uses. `host-sample.json` also has `all_processes`: the CPU each process still running at the end used from the first to the last second of the run (a process that exits during the run isn't in it), totalled and as the 25 largest by name (bench processes as `CodevisorBench:<subcommand>`), so work in a process the list doesn't name still shows. That is how run 41620109016 found that Apple HP captures, encodes and sends in `avconferenced` (AVConference's VideoTransmitter and VCP encoder, and on the viewer its receiver), which the lists missed before 851-3966. Dispatching with `profile: true` also runs `sample` for 10 s, 20 s into each run, on the host's `avconferenced`, `ScreensharingAgent`, `VTEncoderXPCService`, `replayd` and the Codevisor share process, and writes `profile-<process>-<pid>.txt` call trees (and `profile.err` for processes it can't read). Sampling slows the sampled process, so a profiled run's numbers only point at where the time goes. A run is invalid when it didn't come
from the workflow (no `github_run_id`), C2 fails (ε over 0.5 ms or residual over 0.2 ms), another CI job ran,
a preflight found a problem, or over 1% of the viewer's frames were unreadable (except video). `BenchSystemComparison` compares the medians of the valid repetitions. It is a difference when the medians differ by
more than the noise band, the wider of the two systems' min–max spreads, or when each system has at least 3 valid
repetitions and the gap between their ranges is wider than the tighter system's spread, and in either case only when
the medians differ by at least 2% of the larger one, and for CPU by at least 1 percentage point, so near-zero CPU
figures (idle cursor) don't turn a few tenths of a point into a verdict; the verdict table names the rule that fired. Each Codevisor system
(`codevisor-v2`, `codevisor-v2-vcp`) is compared with Apple HP on its own repetitions; the comparison's `system`
names it (absent in reports from before engine v2, meaning engine v1's `codevisor`). With `codevisor-v2` runs the
summary adds the M2
targets (p50 at most the floor + 17 ms, p95 at most the floor's p95 + 50 ms, idle-cursor at most 0.5 Mbit/s, N3 shown
ratio at least 0.9, no image older than 1 s) and a table of v2 stages and counters. Codevisor results carry
`stages_ms` from the viewer's frame timeline (`hostQueue` is `capture_queue`, the jitter-buffer estimate
`decode_queue`), `stages_ms.media` (`queue` and `send` from the host's frame acks, `assemble` from the
viewer) and `media` from both sides' counters. These cover the whole session, not only the measured window.

## Text fidelity: T8 (851-3597)

T8 measures how faithfully each system shows S6 (`test-cards`) at 1:1. A Tier 2 run of `test-cards` adds
`--region full --stills` to both observers for versions 4, 5, 6, 8, 9 and 10 (fewer when the run is short; the
photo card, every fourth version, is skipped; full-display capture makes the observers of these runs costlier than
the barcode strip, so compare test-cards latency and CPU only with other test-cards runs), and `tier2-report` compares the viewer's still of each version with
the host observer's still of the same version. Host font rendering is in both, so it cancels. The metrics live in
`ScreenSharingBench/Fidelity`, and the result is `results[].text` in the v1 report, with every field optional:

- **1:1.** `BenchRegistration` looks for the four corner fiducials (`BenchTestCardLayout.geometry`) in each still:
  a coarse search at ¼ size, then a full-size search for the offset that fits all four, then each fiducial alone
  within ±2 px. The still is 1:1 only when every fiducial lands at the same integer offset and matches its template
  (mean error at most 48 levels). Otherwise the run reports `one_to_one: false` and no numbers, and the summary
  gives the reason (`not_1to1: …`).
- **`psnr_y`, `psnr_y_text`, `ssim_y`** come from the text cards (light and dark). They use BT.709 luma in full range
  (0.2126 R + 0.7152 G + 0.0722 B on the sRGB bytes). PSNR pools the squared error over every compared frame.
  `psnr_y_text` uses only the text mask: reference pixels more than 16 levels from the card's most common luma,
  dilated by 1 px, without the barcode and fiducials. `ssim_y` is Wang 2004 (11×11 Gaussian, σ 1.5, K1 0.01,
  K2 0.03, edges extended), averaged over the frame and then over the frames.
- **`psnr_cbcr`** comes from the chroma card: the PSNR of BT.709 Cb and Cr (full range, pooled), the signal that
  separates 4:4:4 from 4:2:0.
- **`delta_e00_mean`, `delta_e00_p95`** are CIEDE2000 (Sharma 2005; sRGB to CIELAB D65) over the chroma card's
  coloured text: inside each of the six tiles (2 px in from its edges), the pixels more than 32 levels in any channel
  from the tile's most common colour.
- **Report.** An identical frame has PSNR ∞. JSON can't hold that, so the report writes 100 dB, like encode-lab.
  The summary's "Text fidelity" table lists each run, with the frames it compared.

Self-checks. An image compared with itself gives PSNR ∞ and SSIM 1. For a 4:2:0 round trip (2×2 box average of Cb
and Cr, repeated back to full size), one-pixel red/blue stripes give exactly 10.73 dB `psnr_cbcr`, and the
generator's R1 chroma card gives 16.48 dB. Every run's summary also gives the "4:2:0 reference psnr_cbcr", the same
round trip applied to that run's host still. A system above it keeps more chroma than 4:2:0 could.

Apple HP always gives tamale a 1920×1080 pt @2x display (3840×2160 px), so on croissant's 1920×1080 @1x display it is
shown at half size and is never 1:1. The Tier 2 input `viewer-display: R1x2` makes `view` and `apple-hp`
(`--virtual-display R1x2`) create a 1920×1080 @2x virtual display on croissant for each run, show their window
full screen on it, and name it in their ready file, so the viewer observer captures it (barcode blocks scale with
it: 16 px for a 3840 px host). The bench's virtual display gets the system sRGB profile through ColorSync for as
long as it exists (`PlayerDisplayProfile`; if ColorSync refuses, the command warns on stderr and carries on). Left to macOS, it got a generated profile whose tone curve isn't sRGB's,
and sRGB content shown on it came back from the observer's sRGB capture with levels 1–44 one or two lower (851-3989:
grey 40 as 39, which held VCP's dark text card at 48.3 dB `psnr_y`; `vcp-levels` lab runs 42146297995 before,
42147875743 after). Engine v2 streams R1x2 natively at 3840×2160 in four tiles (E5), so its rows
measure the codec alone. `text.stream_size` records the Codevisor stream's encoded size (`capture_size` from `share.json`;
absent for Apple HP, whose encoded size isn't visible), and the table marks a stream smaller than the host's display
"(scaled)".

```sh
gh workflow run bench-screen-sharing-tier2.yml --ref <branch> -f scenes=test-cards -f duration=45 \
  -f floor-repetitions=0 -f c4=false -f viewer-display=R1x2 -f systems=apple-hp,codevisor-v2,codevisor-v2-vcp
```

## Benchmark workflow, results and gate (851-3594)

`Bench screen sharing` (`.github/workflows/bench-screen-sharing.yml`) is the one workflow for numbers. Every job
that measures builds CodevisorBench at its own commit and signs it with the Developer ID in the repository secrets
(`APPLE_CODESIGN_IDENTITY`, team `C4M7D4G7LG`; `.github/actions/build-screen-sharing-bench`,
`scripts/signing-keychain.sh`), into `$RUNNER_TEMP`, and runs it through `CODEVISOR_BENCH_APP`. Synthetic Tier 1
needs no permission grant and never touches `~/Applications/CodevisorBench.app`. Own-window Tier 1 and Tier 2 need
Screen Recording and Accessibility, so they install their build there first (`scripts/install-granted.sh`, see
Tier 2): the minis refused those to a build run from elsewhere, and the grants must be for the CI signing team's app
(see Signing and permissions).

- **Nightly** at 03:00 Pacific (two UTC crons; the `plan` job keeps the one that is 03:00 in Los Angeles), and
  `workflow_dispatch`. The `tier1` job on tamale (concurrency group `screen-sharing-bench`) waits for a quiet machine
  (C5), then runs `scripts/tier1.sh nightly`: the `core-v2` report (S1–S6 at N0 and N3, 3 interleaved repetitions
  of 30 s with 10 s warm-up, about 20 min) and the `gate-v2` report (exactly the PR gate's run: S2, S3 and S5 at N0
  and N3, about 10 min) and the `matrix-v2` report (N1, N2 and N4–N7, 1 repetition, about 20 min), all with
  `--encoder vt`. Each report records its plan in `run.method.plan`, and a baseline
  only uses nightlies of the same plan: the same cell measured among other scenes differs, for example typing's N3
  p95 is about 35 ms in a core run and about 52 ms in the gate's run. Reports from before plans existed match no
  plan, so a new plan's baseline starts empty (`-f plans=gate-v2` seeds it).
  A dispatch with `scenes` or `networks` set runs one `custom` report instead, with the `encoder` input (`vt` by
  default, or `vcp`) (`source` picks `own-window`, which
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
- **PR gate.** A pull request touching `packages/swift/ScreenSharing`, this app, `codevisor-media`, `codevisor-net`,
  `codevisor-net-ffi` or the workflow runs the `gate` job on tamale in its own per-PR concurrency group (so it can't
  cancel a queued nightly or Tier 2 run; the runner takes one job at a time). The `gate` job measures the `gate-v2`
  plan twice (`first-v2.json` and `second-v2.json`, about 20 min), and the `gate` subcommand compares both runs with
  the nightly `gate-v2` baseline using the design §4.2
  rules (`BenchRegressionGate`): a cell fails only when both runs cross a threshold. At N0, latency (p50 up more
  than max(15%, 3 ms), p95 up more than max(20%, 5 ms)) is judged on e2e outside the jitter buffer once the runs and
  every baseline nightly split it out, and the jitter buffer gets its own rule (p50 up more than max(100%, 40 ms));
  N3 is judged on whole e2e, where jitter-buffer growth under loss is a regression. The jitter buffer's
  wait can swing between processes independently of the rest of the pipeline, so N0 judges it on its own. The summary also
  says how long the gate waited for tamale and which bench runs were active meanwhile. A cell's baseline only reads
  cells of its own system.
  Closing or merging the pull request starts a `stop-gate` job on a GitHub-hosted runner in that group, which
  cancels a gate still queued or running for it.
- **One build a night.** The `build` job builds and signs CodevisorBench once on tamale and uploads it as the
  `bench-app` artifact (`.github/actions/keep-screen-sharing-bench`, a ditto zip); Tier 1 and both Tier 2 dispatches
  fetch that build (`fetch-screen-sharing-bench`), so the night measures one binary. `tier1: false` skips Tier 1 in a
  dispatch, to try calibration or Tier 2 on their own.
- **Calibration and Tier 2** run after Tier 1 through `workflow_call` when the dispatch inputs ask for them, or every
  night once the repository variable `SCREEN_SHARING_BENCH_NIGHTLY_TIER2` is `true`. Calibration still uses the installed
  app. The nightly Tier 2 covers every scene in two dispatches of under 30 minutes, `apple-hp` and `codevisor-v2`
  side by side, 2 repetitions of 30 s and a floor per scene (input with 40 presses and 40 clicks, which fit 30 s):
  `tier2-a` runs idle-cursor, typing, scroll and window-drag at N0 (21 runs with the Apple HP warm-up, about 21
  minutes of runs), then `tier2-b` runs video (with C4), test-cards and input at N0 (18 runs), except on odd days since
  the Unix epoch (UTC), when it runs input at N0 and scroll and typing at N3 instead (`input,scroll@N3,typing@N3`, 16
  runs). The `tier2_b_scenes` dispatch input overrides that choice. `tier2-summary` then runs `tier2-dispatches` on
  both reports (`.github/actions/tier2-dispatches-summary`): each dispatch's display phase and 851-4092 status, image age
  by dispatch, and v2's verdicts within each dispatch.
- **Weekly Apple HP.** Apple HP's image age swings between dispatches (typing 22.0 / 37.8 / 22.5 / 30.9 / 82.3 ms in
  five, 851-3975) while its repetitions within one agree, so one dispatch can't settle a verdict against HP.
  `Bench screen sharing tier 2 weekly` (`.github/workflows/bench-screen-sharing-tier2-weekly.yml`, Saturdays 20:00 UTC
  and `workflow_dispatch`) builds once and runs three dispatches in a row of typing, scroll and window-drag at N0
  (`apple-hp,codevisor-v2`, 2 repetitions of 30 s, about 17 minutes each). Its summary gives HP's image age as the
  median across the dispatches of each dispatch's median, and judges v2 against HP only within each dispatch.

`preflight --quiet` is C5. It waits at least `--settle` seconds (60) and up to `--settle-limit` (300) for the
1-minute load to drop to 2.0 and Spotlight to stop indexing (a fresh build sets it off), then fails on a thermal state other than nominal, Spotlight indexing (`mds_stores` or
`mdworker*` above 5% CPU), Time Machine or `softwareupdate` running, en0 not up at 1000baseT, other regular apps
open (Finder aside), anyone screen sharing into the Mac, or a locked session (`--allow-locked` skips that check for
offscreen Tier 1). It also fails when load and Spotlight never stayed quiet for 3 samples in a row before the
limit (`reached_settle_limit`). `loopback` records Spotlight indexing in `environment.host.spotlight_busy`. The
`plans` dispatch input (`core-v2`, `gate-v2`, `matrix-v2`; empty runs all three) applies to the nightly plan only; a dispatch with
`scenes` or `networks` set runs one custom report and warns if `plans` was given.

```sh
gh workflow run bench-screen-sharing.yml -f kind=nightly                    # the nightly plan, recorded as a baseline
gh workflow run bench-screen-sharing.yml -f kind=nightly -f plans=gate-v2   # only the gate's baseline (about 12 min)
gh workflow run bench-screen-sharing.yml -f scenes=scroll -f networks=N0,N3 # an ad hoc codevisor-v2 run
gh workflow run bench-screen-sharing.yml -f scenes=scroll -f networks=N0 -f encoder=vcp   # an ad hoc codevisor-v2-vcp run
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
- **Configs.** `--configs` takes `;`-separated `key=value` lists; every key defaults to engine v1's product encoder,
  kept as the lab's baseline (`product`, `EncodeLabConfig.productBaseline`: HEVC 4:4:4, standard rate control, speed over quality, 45 Mbit/s, 2560×1440,
  a keyframe every 60 s; `hevc` and `h264` default to low-latency rate control without speed priority). A `preset`
  or `cq` keeps its own bitrate and speed unless `mbps` or `speed` is given too.
  Keys: `name`, `engine` (`vt`, or `vcp` below), `codec` (`hevc444`, `hevc`, `h264`), `rc` (`standard`, `ll`), `mbps`
  (or `none`), `size`, `tiles` (horizontal stripes, one session each, the bitrate split evenly), `skip` (encode only the
  tiles whose pixels changed), `ltr`, `yuv`, `speed`, `mfd` (`MaxFrameDelayCount`), `qpmax`, `qpmin`, `drl` (`<mbps>@<seconds>`),
  `preset` (`vc`, `speed`, `balanced`, `quality`), `cq` (`ConstantQualityFactor`, macOS 27), `aq`, `ackms` (the
  simulated round trip before a reference token is acknowledged, 33 ms by default), `refine` (after each change,
  resubmit the unchanged frame up to N times, every other tick, so the encoder can sharpen it), `refineqp`
  (`MaxAllowedFrameQP` for those resubmissions only; the next change goes back to `qpmax`, or to no cap), `vcpin` and
  `nodirty` (VCP only: `DisableDirtyDetection` in the encoder specification, as AVConference passes it; no effect on
  tamale, run 41557954805), and `split` (VCP only: one session per tile, as engine v2 runs it, each with its share of
  `mbps` and `drl`).
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
  source converted to 4:4:4 (BT.709, video range) on the CPU, rounded to 8 bits: PSNR of Y and of Cb/Cr (4:2:0
  chroma upsampled by nearest neighbour) and SSIM of Y (Wang 2004, 11×11 Gaussian, σ 1.5). A single-tile config smaller than the canvas is also
  upscaled back and compared with the native frame (`native`), so downscaling counts against it; tiled configs get
  no native score. `engine=vcp` with `444f` input is compared in full range, the range it encodes. **Settled** scores
  the last pass of every version held for at least 0.5 s, after its refinements: the still a viewer keeps looking at,
  which is what T8 measures on test cards (851-3975). The reference shares no code with the encoder's input
  conversion (`VTPixelTransferSession`): when it did, the input conversion's errors cancelled out, and the lab never
  showed the white at 254 that VCP's input had on the minis' M6 (851-4049).
- **CI.** Dispatch `Bench screen sharing` with `encode_lab` set to the configs (and `encode_lab_options` for the
  rest); that runs only the `encode-lab` job on tamale and puts the table in the job summary.

## Lab job

`gh workflow run bench-screen-sharing.yml --ref <branch> -f lab='croissant player --display virtual --resolution R1x2'`
runs only the `lab` job. `-f lab='croissant network-lab'` instead measures each Tier 2 network on croissant alone
(`scripts/tier2-network-lab.sh`): it loads each network's shaping (ICMP is shaped like the sessions' TCP and UDP),
pings tamale 600 times 0.1 s apart and prints the loss, the round trip's min, p50, p95 and max, and the loaded pf rules
and table. It builds and installs the bench on the named mini (`tamale` or `croissant`), then runs
`scripts/lab.sh`: one subcommand, with a preflight 8 s in so its display list shows what the command created. The
command's output goes to the job summary and the `lab` artifact. The job has its own concurrency group
(`screen-sharing-lab-*`), so check `gh run list` and agree on the mini first. The first lab run (41267527233) showed
that croissant's M6 brings a 1920×1080 @2x virtual display (3840 px of backing) online.

## Host lab (851-3966)

`host-lab` measures the engine v2 host's CPU on one Mac, without a viewer, for several variants in one run:

```sh
CodevisorBench host-lab --scenes scroll,typing --seconds 30 --settle 5 --virtual-display R1x2 \
  --variants base/queue=6/cursor=0/refine=1/tiles=1/ltr=0
```

- It creates the virtual display, then for each scene starts `player` on it and, for each variant, a `host-run`
  child: ScreenSharingCapture → ScreenSharingV2Host → the VideoToolbox tile encoder → a null transport that drops
  the tiles and acknowledges every LTR token at once. After `--settle` seconds it samples CPU for `--seconds`.
- A variant is `base` or comma-separated settings: `queue` (ScreenCaptureKit queue depth), `cursor`, `fps` (capture
  and encoder rate), `refine` (refinement passes), `converge` (a refinement pass under this many bytes ends the tile's refinement; 0 is off); either one replaces the encoder's own policy (VCP's 200-byte convergence included); without either, the run uses the encoder's policy, as the product does, `tiles` (1 or 4), `ltr`, `vcp` (1 runs the VCP tile encoder instead of VideoToolbox, on its BGRA capture) and
  `bgra` (1 captures BGRA for VideoToolbox too, so the capture format's cost shows apart from VCP's, 851-3975).
- The table gives the whole system (`all_processes`), the `host-run` child, `VTEncoderXPCService`, `WindowServer`,
  `replayd` and the player, plus captures, tile encodes and refinements per second and the encode p50. The network
  send path isn't in it; `media-transport` measures that.
- **CI.** `-f lab='tamale host-lab --scenes scroll,typing --variants base/cursor=0'` runs it in the lab job; the table
  is in the job summary.

## Encoder release (851-4009)

`encoder-release` checks whether the VCP tile encoder gives the Mac's hardware HEVC encoders back when it stops. In one
process it opens and stops a `ScreenSharingVCPTileEncoder` (`--rounds`, 3 by default, at `--width` × `--height`,
3840×2160 by default), encoding one frame each time. Before, while the first one is open, and after each round
(`--settle` seconds later, 2 by default), it starts a second copy of itself (`--count-vt <limit>`) that opens low-latency
VideoToolbox HEVC sessions (1920×544, one frame each) until one fails, and reports how many worked and the status that
stopped it. A leak shows as a count that stays below `before` after a round. On an M1 Pro (macOS 27.2) the count is 32
before, 24 while a 4-tile VCP encoder is open and 32 after every round. In CI:
`-f lab='tamale encoder-release --rounds 3'`.

## VCP levels (851-3989)

`vcp-levels` pushes grey and colour patches (one flat 32×32 px patch for each grey level, then a row of colours,
1024×288) through each stage of engine v2's VCP path on this Mac, and reports every patch that changes (`mismatches`,
as `expected→shown`, Y,Cb,Cr or R,G,B). Each of three inputs (BGRA through the engine's converter, and `444f`
converted on the CPU, with and without the session's colour tags) is encoded by a 1-tile `ScreenSharingVCPTileEncoder`
at 60 Mbit/s, a change and then `--passes` − 1 refinements (5 in all by default), and decoded as the viewer does. Its
stages are the `444f` decode, the viewer shader (`ScreenSharingMetalView.shader`) drawing that decode 1:1 into a BGRA
texture, and a decode to BGRA. The shader and BGRA stages expect the exact 8-bit full-range round trip, so saturated
colours that 4:4:4 can't hold exactly (red 255 comes back as 254) don't count. `conversions` gives
`VTPixelTransferSession`'s BGRA → `444f` and `444v`. Unless `--no-capture` is given, it also shows the picture on the
main display (or on a `--virtual-display`, as Tier 2's viewer does) and captures it with ScreenCaptureKit (`captures`:
the window as BGRA, `444f` and `420v`, and the display as BGRA), and shows a VCP decode, a `420v` picture and BGRA
through both engine v2 viewer surfaces and captures them from the display as T8's observer does (`presentations`).
`display_before` and `display_after` name the display's colour space. In CI:
`-f lab='tamale vcp-levels'` or `-f lab='croissant vcp-levels --virtual-display R1x2'`.

Findings (macOS 27.2): on the minis' M6, the converter, VCP, the decoder and the shader are exact for every patch.
ScreenCaptureKit's `444f` is up to 32 levels off on colours, with or without a BT.709 `colorMatrix`, so engine v2
keeps capturing BGRA and converting it itself (851-4049).

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
