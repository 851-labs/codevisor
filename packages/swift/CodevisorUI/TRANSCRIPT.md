# Transcript presentation and performance

AppKit and UIKit now use `TranscriptSurfaceController` for row updates, geometry
state, initial scroll policy, stream-arrival eligibility, and presentation-frame
ordering. `TranscriptSurfaceAdapter` and `TranscriptFrameAdapter` perform native
side effects. `TranscriptSurfaceOwner` exposes the shared stored values without
introducing copy-on-write copies through forwarding accessors.

The controller commits each frame in this order: accept pending model changes,
mount the required rows, commit eligible measurements, advance text reveals,
then finish native presentation work. Requests raised during that work survive
for the next frame. UIKit still defers measurement commits during momentum;
AppKit still owns its host retirement, selection, and send animation.

The shared Markdown text-run renderer produces the attributed strings for prose,
headings, lists, nested lists, and compatible quotes on both platforms. Small
typography adapters preserve native font styles, links, and pointer behavior.
TextKit quote decoration and attributed-string caching are shared. Tables and
native text-view ownership remain platform specific: macOS uses its native table
renderer and retains transcript surfaces; iOS uses the SwiftUI table renderer and
reconstructs native surfaces when navigating back.

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
| Parse a growing Markdown source | Full-source parsing remains; repeated tiny appends can accumulate quadratic work |

This is bounded row mounting, not virtualization inside every block. A single
huge paragraph, code block, or table can still require substantial layout work.
Value equality and cache-key hashing also have content-dependent costs. The
implementation does not promise constant-time rendering or zero dropped frames.

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

The remaining priorities are bounding layout inside huge blocks, replacing or
virtualizing iOS table layout, reusing iOS native content more effectively on
cached return, and incremental parsing with a correct invalidation frontier.
Large-block cold stalls remain measurable. Simulator accessibility page-scroll
actions also do not currently update follow intent like touch gestures; the
scrolling checks used touch input before paging. Accessibility inspection itself
can stall when asking AppKit for an attributed substring of the enormous table,
so those inspection pauses were excluded from rendering conclusions.

An attempted iOS Animation Hitches capture reported that the instrument was
unsupported on the simulator. The macOS capture did not establish reliable
frame coverage. Neither capture supports a claim of zero hitches. Release-build
frame measurements on physical devices remain necessary for that target.

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
