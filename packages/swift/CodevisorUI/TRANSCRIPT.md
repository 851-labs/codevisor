# Transcript presentation and performance

AppKit and UIKit now use `TranscriptSurfaceController` for row updates, geometry
state, initial scroll policy, stream-arrival eligibility, and presentation-frame
ordering. `TranscriptSurfaceAdapter` and `TranscriptFrameAdapter` perform native
side effects. `TranscriptSurfaceOwner` exposes the shared stored values without
introducing copy-on-write copies through forwarding accessors.

The controller commits each frame in this order: accept pending model changes,
mount the required rows, commit eligible measurements, advance text reveals,
then finish native presentation work. Requests raised during that work survive
for the next frame. During UIKit momentum, visible rows and rows below them
can commit measured heights without changing the scroll offset. Corrections
above the first visible row wait until momentum ends so the reading anchor can
be compensated. AppKit owns its host retirement, selection, and send animation.

SwiftUI row hosts observe the natural size of the placed content through
`TranscriptContentLayoutObserver`. Native layout callbacks no longer probe
`sizeThatFits` or wait for scheduler yields to guess when SwiftUI has reconciled
an update. Root generations reject obsolete callbacks, and an explicit request
revision lets readiness changes re-report an unchanged size. Cached heights
position a row immediately; the placed layout confirms or corrects them.
Unchanged geometry produces no further height reports. The settled AppKit
renderer similarly verifies ledger heights using its retained native layout.
UIKit updates each row's clipping mask in the same frame assignment as its
committed height, including frame changes that bypass the bounds setter.

The clipping regressions exercise an AppKit row that retained a 16-point height
after its text grew to 384 points, and a UIKit row whose frame grew from 180 to
260 points while its mask stayed at 180. Both now update correctly. Tests also
cover cached heights, reflow, unchanged-layout report counts, and momentum
corrections that preserve the native scroll offset. A focused macOS debug
benchmark on September 12, 2026 alternated four runs of 200 text updates and
500 unchanged layouts per implementation. Mean text-update time was 0.362 ms
before and 0.365 ms after; unchanged layouts averaged about 0.004 ms in both.
These are hosting-controller CPU measurements, not device scrolling frame times.

The shared Markdown text-run renderer produces the attributed strings for prose,
headings, lists, nested lists, and compatible quotes on both platforms. Small
typography adapters preserve native font styles, links, and pointer behavior.
TextKit quote decoration and attributed-string caching are shared. Both apps
retain native transcript surfaces through the shared `TranscriptPresentationCache`.
Attached surfaces are protected; detached retention is limited to six on macOS
and three on iOS. iOS also discards detached surfaces on memory pressure. A new
SwiftUI navigation container reattaches the retained UIKit controller and installs
fresh callbacks. Disclosure state, measured row hosts, and text layout survive
that transition. Width, typography, theme, and preview namespace participate in
layout invalidation.

Native table presentation remains platform specific. macOS uses TextKit's table
layout and native selection/copy. iOS prepares immutable attributed cells and
prefix geometry off the main actor, then mounts native text views only for the
visible rows and columns. Its nested horizontal scroll view stays close to the
vertical transcript viewport, even when the semantic table is hundreds of
thousands of points tall. This avoids document-sized UIKit rendering surfaces.
Both tables preserve horizontal overflow and fill the complete header width.

Large blocks first encountered as settled content prepare their attributed text
and TextKit layout on a worker. The displayed native view adopts that same layout
stack, avoiding a second main-actor typesetting pass. Small content stays on the
synchronous path. A block that starts as live content keeps its presentation path
through completion to preserve selection and reveal identity. Syntax snapshots
match source, language, and theme; an append can keep valid prefix colors while
its new tail awaits highlighting. Same-length edits invalidate stale colors.

`LatestValuePreparationWorker` allows one executing request and one replaceable
pending request per worker. It publishes useful intermediate results during a
continuous stream and rejects results from a canceled presentation generation.
TextKit stacks have exclusive worker ownership until publication, then UI actor
ownership. Unprepared content cannot commit placeholder heights to the transcript
measurement ledger, including measurements queued before readiness changes.

Animation identity follows provider text, independently of a row's current
section. Moving a response into a worked section therefore does not replay that
response. Layout identity remains separate so the native host can change when
the presentation changes. Unchanged Markdown prefixes ignore changes to the
whole source string when comparing rendered content. Measurement revisions cover
the complete rendered blocks, including table cells and inline styles.

Navigation is a presentation boundary. Suspending a transcript settles known
streams and clears pending reveal work. Its first authoritative projection on
return settles both appended text in existing rows and newly arrived rows. Later
visible arrivals can animate. A published projection revision can establish that
baseline while another revision is pending, so continuous streaming cannot
prevent restoration. A saved bottom position follows the latest content; a saved
non-bottom position restores the row anchor and offset. Animation eligibility
also requires the foreground presentation and permission to animate live text.

The geometry index uses an immutable balanced tree with leaves of at most 32
rows. Old snapshots share unchanged nodes, so measurement corrections can
preserve the previous geometry for anchor compensation without copying every
offset. With R rows, K changed heights, and V mounted rows:

| Operation | Current work |
| --- | --- |
| Build geometry after row topology changes | O(R) |
| Correct one height, retaining the old snapshot | O(log R) time and additional storage |
| Correct a batch | O(K log K + K log R) upper bound; affected subtrees are shared within the batch |
| Find the visible range or restore an anchor | O(log R) |
| Position V native hosts | O(V log R) |
| Export all heights or offsets for diagnostics | O(R) |
| Patch a stable active row slice | Proportional to the active slice when uniquely owned; retained Array/Dictionary snapshots can still cause O(R) copies |
| Parse an append without reference syntax | Reparse the mutable top-level tail; reuse complete prefix blocks. Prefix comparison still costs O(N), and assembling the block array costs O(B) |
| Parse an edit or source containing `[` | Conservative full-source parse, preserving global reference-link semantics |
| Find visible iOS table cells | O(log T + log C + V), with T table rows, C columns, and V visible cells |
| Prepare iOS table geometry | Measure all cells off the main actor; O(T × C) cell visits plus text shaping costs |

Here N is source length and B is the number of top-level blocks. A bounded parser
cache retains at most 16 documents within an estimated 8 MiB budget. MD4C records
a conservative reparse boundary; reference definitions, edits, and unsupported
tail boundaries retain full-document semantics. Mutable parser builders also
avoid repeatedly copying growing child arrays.

This does not virtualize layout inside every block. A giant paragraph or code
block still requires complete initial shaping, now moved off the main actor when
first encountered as settled content. A growing single block and sources with
reference syntax can still accumulate quadratic parsing work. Equality, hashing,
and native layout have content-dependent costs. Separate workers can execute
concurrently; the request bound is per worker, not a global concurrency limit.
The implementation does not promise constant-time rendering or zero dropped frames.

The macOS code-block fix removes a separate unbounded `boundingRect` typesetting
pass. It measures the actual TextKit 2 layout once for immutable source and font;
subsequent syntax colors do not trigger another geometry measurement. The former
pass was especially expensive after highlighting split the text into many runs.

## Verification recorded September 8, 2026

Both development apps ran against the normal local server and durable transcript
history APIs. The iOS run used an iPhone 17 Pro simulator on iOS 27; the host was
a Mac Studio (Mac16,9), 36 GiB memory, macOS 26.6.1. These are debug observations
from individual stress runs, not release benchmarks or physical-iPhone results.

Fixtures included 500 mixed turns (roughly 15 MB of Markdown), a paragraph with
4,000 repetitions containing styles, emoji and Japanese text, a 5,000-line Swift
code block, and a 2,000-row, three-column table. Mixed turns contain long prose,
120-line code blocks, 80-row tables, and nested lists/quotes. Separate live
fixtures exercised navigation and a 300-chunk stream paced at ten chunks per
second. Pacing generated the workload; correctness tests use explicit events and
controlled clocks.

| App scenario | macOS | iOS |
| --- | --- | --- |
| Open uncached 500-turn history | Initial page rendered; history stayed paged | Initial page rendered; history stayed paged |
| Scroll and fetch older history | Loaded row count 40 → 76 → 112 | Loaded row count 40 → 76 |
| Return to cached 500-turn chat away from bottom | Same anchor and offset; zero offset change | Same anchor and offset; zero offset change |
| Leave at bottom, append while hidden, return | At bottom; returned content settled | At bottom; returned content settled |
| Append after returning | New text animates before the turn finishes | New text animates before the turn finishes |
| Leave away from bottom, append below, return | Same anchor and offset; no reveal replay | Same anchor and offset; no reveal replay |
| Move first text part into worked section | Only the second part had an active fade | Only the second part had an active fade |
| Return during continuous streaming | Stayed at bottom; later arrivals animated | Stayed at bottom; later arrivals animated |
| Finish the streamed turn | No completion replay | No completion replay |
| Scroll the huge paragraph, code, and table | Content remained navigable | Content remained navigable |

Native traces measure CPU time inside configuration, mounting, geometry, and
the shared display-link callback. The following values are the maximum observed
duration for the indicated operation in its scenario. Nested operations overlap
and must not be added together. These values exclude some history/projection
latency and do not measure click-to-paint latency, GPU work, or total frame time.

| Scenario / operation | macOS | iOS |
| --- | ---: | ---: |
| 500-turn cold open: configuration | 28.14 ms | 31.97 ms |
| 500-turn cached return: configuration | 0.32 ms | 87.35 ms |
| Scrolling through older pages: mounting | 16.26 ms | 4.72 ms |
| Scrolling through older pages: shared frame callback | 15.23 ms | 10.26 ms |
| Continuous stream: shared frame callback | 1.98 ms | 1.32 ms |
| Huge paragraph: cold configuration | 745.35 ms | 2,874.16 ms |
| 5,000-line code: cold configuration after fix | 78.11 ms | 175.78 ms |
| 2,000-row table: cold configuration | 254.31 ms | 1,443.97 ms |

Before the code-block fix, macOS cold configuration took 3,129.23 ms for the same
5,000-line fixture. A main-thread sample also found the subsequent highlighted
`boundingRect` pass stuck in Core Text typesetting. After the fix, highlighting
completed without that second measurement stall and the block could be scrolled.
This before/after comparison is one debug workload, not a statistical speedup
claim across arbitrary code.

The 20,000-row Swift debug benchmark measured 0.012 ms for six height corrections,
0.015 ms for anchor planning, and 0.097 ms for window planning. Full geometry
construction remained 17.39 ms. The retained-row-set-copy benchmark still took
3.37 ms per active replacement. A deterministic operation-count test verifies
that correcting one height among 131,072 rows visits exactly 13 tree nodes while
preserving the previous snapshot.

Validation passed: 1,672 shared Swift tests, 19 macOS native transcript tests,
nine server transcript/driver tests, server type checking, Swift formatting and
lint, and both native development builds. Added regressions cover geometry
boundaries and snapshot persistence, shared frame ordering, navigation policy,
hidden stream restoration, continuous pending projections, semantic animation
identity, Markdown invalidation, list-marker layout, and color-only code updates.

The local numerical evidence is under `tmp/transcript-performance/`, including
`final-live`, `final-part-transition`, `final-continuous`, `final-completion`,
`final-mixed-open`, `final-mixed-cached`, `pagination-scroll`, `hidden-arrivals`,
`resumed-stream`, and `static-return` phase captures. This ignored directory is
local run output. Anchor hashes identify rows only within one app process. Phase
captures may include outgoing-surface events during navigation; restoration
comparisons use the target surface's departure/return coordinates.

These September 8 observations precede the preparation, table virtualization,
and UIKit retention changes below. The older AppKit table accessibility stall
also preceded the bounded attribute export: large accessibility substring queries
now copy supported text attributes without the expensive native table block graph.

An attempted iOS Animation Hitches capture reported that the instrument was
unsupported on the simulator. The macOS capture did not establish reliable
frame coverage. Neither capture supports a claim of zero hitches. Release-build
frame measurements on physical devices remain necessary for that target.

## Verification recorded September 9, 2026

The same development workloads ran on the Mac Studio and iPhone 17 Pro simulator.
Each number below is an observed maximum CPU callback duration from an individual
run, with the same exclusions described above. The large blocks were also
visually checked after preparation; placeholder-only captures are excluded.

| Scenario / operation | macOS | iOS |
| --- | ---: | ---: |
| Huge paragraph: cold configuration | 35.12 ms | 68.91 ms |
| 5,000-line code: cold configuration | 19.33 ms | 26.03 ms |
| 2,000-row table: cold configuration | 11.72 ms | 35.62 ms |
| 2,000-row table: retained return configuration | — | 0.15 ms |
| 500 mixed turns: cold configuration | 28.70 ms | 37.15 ms |
| 500 mixed turns: retained return configuration | — | 0.18 ms |
| Mixed history pagination: largest observed shared frame callback | 28.72 ms | 13.26 ms |
| iOS older-page boundary: configuration | — | 29.55 ms |
| Continuous stream with navigation: shared frame callback | 1.29 ms | 3.60 ms |
| Text-part transition: configuration | 18.90 ms | 33.47 ms |

The iOS table returned with painted cells and the exact saved anchor and offset.
Wide tables reached their final columns on both platforms; header backgrounds
covered the final edge, and vertical dragging over an iOS table scrolled the
transcript. Mixed history loaded older pages while retaining a bounded mounted
window, rather than constructing views for all 500 turns.

Repeated cached returns restored the exact row and offset. The iOS check also
covered accessibility page scrolling: the viewport is captured before window
detachment, independently of UIKit's touch callbacks. Both apps returned to the
bottom after hidden arrivals with zero active reveals. A 200-chunk stream paced
at ten chunks per second continued across navigation; both apps restored while
generation was active and animated later visible chunks. Moving the first text
part into a worked section left one active reveal for the new part. Completion
produced zero active reveals. Native macOS table selection copied the selected
fixture text exactly; iOS table cells reflowed at an accessibility Dynamic Type
size and returned to the original size after restoring the setting.

`bun run check` passed, including JavaScript checks and coverage, 1,689 shared
Swift tests, 20 native macOS transcript tests, formatting, lint, and the iOS
build. Both native development apps were built and exercised. Added regressions
cover incremental parsing versus full parsing at every fixture prefix, global
reference invalidation, bounded pending work and cancellation, native prepared
layout/selection, table geometry and accessibility export, presentation retention,
and rejection of placeholder heights during restoration.

These changes substantially reduce large-block main-actor stalls, but cold
configuration and some pagination bursts still exceed a 16.67 ms frame budget.
Native cell layout during mounting, many newly visible blocks, full shaping of
large live blocks, and O(R) topology rebuilds remain optimization opportunities.
These debug traces establish neither zero dropped frames nor physical-device
performance. Correctness tests assert semantics and operation bounds, not elapsed
time thresholds.

Local captures are under `tmp/transcript-performance/renderer-*`. Summarize any
capture without relying on a particular machine's paths:

```sh
node scripts/transcript-performance-summary.mjs /path/to/trace.jsonl
```

The summary reports counts, p50, p95, and maximum CPU durations by event and the
last viewport snapshot. Navigation captures can contain multiple surfaces; use
the target surface's departure and return anchors when evaluating restoration.

## Rebase verification, September 9, 2026

The renderer branch was rebased onto `origin/main` at `1297160f`. The normal
`bun run dev` runner rebuilt and launched both apps against the shared local
server. Fresh processes repeated the same large-block workloads; macOS and iOS
used equivalent seeded text. The iOS simulator's expired duplicate development
connection was removed before its measurements.

| Cold configuration, maximum CPU callback | macOS | iOS |
| --- | ---: | ---: |
| Huge styled paragraph | 29.20 ms | 41.00 ms |
| 5,000-line code block | 17.12 ms | 24.73 ms |
| 2,000-row table | 11.42 ms | 19.04 ms |
| 500 mixed turns | 11.13 ms | 36.06 ms |

The retained iOS mixed transcript returned with a 0.27 ms maximum configuration
callback. Returning to the large table after accessibility page scrolling took
7.62 ms and restored its 724-point bottom distance with painted cells. These
remain individual debug observations, not total presentation latency or frame
coverage. The full-height visual check matters: the first post-rebase macOS
paragraph capture was invalid because its host retained a 320-point placeholder.

That run exposed a root-replacement race in AppKit. Replacing a SwiftUI root
preserves pending preparation and the unresolved preference's identity, so the
host must preserve that readiness too. Resetting it prematurely loses the final
measurement invalidation. A controlled native test reproduces the stale height
with and without a cached measurement; another exercises actual worker-prepared
Markdown. The corrected development app measured and displayed the full
34,558-point paragraph instead of clipping it to the placeholder.

The repeated scrolling pass also exposed an iOS input classification gap:
accessibility paging bypasses touch delegate callbacks. Native movement outside
our position transactions now clears follow intent at a stable viewport size.
Both apps loaded an older page (39 to 75 projected rows); observed configuration
peaks at that boundary were 22.05 ms on macOS and 28.39 ms on iOS. Neither app
constructed views for all 500 turns. After leaving partway up, receiving 16
hidden chunks, and returning, viewport coordinates matched exactly: 17,202 points
on macOS and 18,088 points on iOS, measured as document height minus bottom
distance. New content below the viewport changed bottom distance without moving
the reading position.

A 200-chunk stream paced at ten chunks per second, including navigation, had
maximum shared frame callbacks of 2.56 ms on macOS and 3.19 ms on iOS on the
final rebuild. This does
not include all model/configuration work: those callbacks peaked at 20.50 and
34.95 ms. A large iOS jump from old history back to the live edge incurred a
103.43 ms configuration/mounting burst, and a text-part transition peaked at
30.29 ms on macOS and 46.29 ms on iOS. Those spikes remain optimization work;
the steady-state frame figures must not be used to hide them.

The first appended chunk after an iOS cached return exposed a late animation
baseline. Baselines now begin before native attachment/configuration, and the
shared coordinator publishes its reset even when already idle. This wakes
retained text immediately instead of waiting for a new chunk to discover the
baseline. A deterministic observation/reconciliation regression checks opaque
restored text and animation of the first following append.

The final rebuild repeated this in both apps with the same unfinished paragraph:
a hidden append returned with zero active reveals, then the first visible append
produced one active reveal without changing the 43-row topology. Both stayed at
the bottom. The earlier new-paragraph variant also passed. The focused shared
presentation suite passed all 19 tests, including the new idle-row observation
regression.

The shared 20,000-row benchmark also ran after rebasing: six incremental height
corrections took 0.005 ms, anchor planning 0.005 ms, viewport window planning
0.097 ms, and full layout construction 16.943 ms per iteration. These benchmark
averages measure different work from the native maximum callbacks above.

## Repeat the workload

From the worktree root, start exactly one normal runner with tracing enabled:

```sh
TRANSCRIPT_STRESS=1 bun run dev
```

Set `CODEVISOR_IOS_SIMULATOR` on that command to select a dedicated simulator.
In another terminal, set `TRANSCRIPT_STRESS_URL` to the local server URL printed
by this worktree's runner. Then create any of the presets:

```sh
node scripts/dev-transcript-stress.mjs seed mixed
node scripts/dev-transcript-stress.mjs seed paragraph
node scripts/dev-transcript-stress.mjs seed code
node scripts/dev-transcript-stress.mjs seed table
```

Each command prints a `sessionId` and leaves its final turn open. Open that chat
in both apps, then control arrivals explicitly:

```sh
node scripts/dev-transcript-stress.mjs chunk <sessionId> "Visible live text."
node scripts/dev-transcript-stress.mjs chunk <sessionId> --stdin < /path/to/chunk.md
node scripts/dev-transcript-stress.mjs finish <sessionId>
```

Finish fixtures before restarting the runner unless testing interrupted turns;
otherwise the normal recovery path marks their open turns as interrupted.

The driver posts acknowledged events through the ordinary durable materializer
and fanout; it never calls a model. For custom workloads, POST JSON to
`/dev/transcript-stress` using `action`, `sessionId`, and `text`. `seed` also
accepts `folderPath`, `title`, and `turns` (1–10,000); `chunk` accepts `messageId`
and `phase` (`commentary` or `final`) for text-part transitions. Only fixtures
created by that server process can receive driver chunks or finish events. The
route is disabled without `TRANSCRIPT_STRESS=1` and rejects requests with Origin
headers. The fixtures live only in the selected development server's database.

Native debug apps write `codevisor-transcript-performance.jsonl` in their native
temporary directory. On macOS this is normally under the shell's `TMPDIR`; on
iOS it is inside the app data container's `tmp` directory, obtainable with
`xcrun simctl get_app_container <simulator-UDID> <development-bundle-ID> data`.
The first record in a new app process replaces the old trace. Records contain
numeric timings and geometry, never transcript text; file writes run on a serial
utility queue. Tracing is disabled in production builds.

Use a fresh process for cold opens. For cached returns, leave and return within
the same process. Allow native deceleration to finish before recording the
departure anchor. While away, append both to an existing paragraph and to a new
paragraph; on return those arrivals should be opaque, and the next visible chunk
should animate. Repeat from a non-bottom position and across older-page loads.
Compare visible content as well as the trace: a short frame callback alone does
not establish a responsive end-to-end presentation.
