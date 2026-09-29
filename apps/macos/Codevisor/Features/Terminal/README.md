# Workspace Terminals (libghostty)

Terminals live in workspace tabs and split panes, alongside chats and plugins.
The sidebar lists those tabs, and each terminal uses its workspace's directory.

> **Status: live.** `GhosttyKit.xcframework` is built and linked, so each pane
> runs a real libghostty terminal. The framework and runtime resources are
> required build inputs; missing Ghostty assets should fail the build.

## How GhosttyKit is built & linked

1. `apps/macos/scripts/build-ghostty.sh` produces
   `apps/macos/Frameworks/GhosttyKit.xcframework` (macOS, iOS, iOS Simulator).
   It downloads a pinned [libghostty-spm](https://github.com/Lakr233/libghostty-spm)
   release, verifies its SHA-256, and repackages it as the `GhosttyKit` module.
   That release is upstream Ghostty at a pinned commit plus libghostty-spm's
   patch set, which adds what Codevisor needs: a host-managed I/O backend (the
   app feeds the surface the server's PTY output and receives its input, with
   no local subprocess), replay that doesn't re-answer old terminal queries,
   and the iOS slices upstream no longer builds. Sentry is compiled out. Dev
   bootstrap fetches the same stamp from the shared artifact cache, or runs the
   script when it isn't published yet.
2. Linked into the Codevisor target via build settings:
   - `SWIFT_INCLUDE_PATHS` points at the GhosttyKit macOS slice headers.
   - `OTHER_LDFLAGS = -force_load .../libghostty-internal-fat.a -lc++` + Metal,
     MetalKit, QuartzCore, CoreText, CoreGraphics, CoreVideo, IOSurface, IOKit,
     Carbon, AppKit, Foundation, CoreFoundation, Security, ApplicationServices,
     AudioToolbox, UniformTypeIdentifiers, GameController, Combine.

`CodevisorGhosttyApp` writes a temp config with the app's terminal font size so
the embedded terminal scale matches the rest of the app chrome. It deliberately
sets no `font-family`: libghostty compiles its default font (JetBrains Mono +
Symbols Nerd Font) into the static library, so leaving the family unset renders
the same glyphs, metrics, and ligatures as stock Ghostty.

**Resources:** the `xterm-ghostty` terminfo + shell-integration are bundled as
`Codevisor/Resources/ghostty-resources.tar.gz` (layout: `ghostty/shell-integration`
+ `terminfo/{67,78}`). On first launch `CodevisorGhosttyApp` extracts it to
`~/Library/Application Support/Codevisor/ghostty-resources/` and sets
`GHOSTTY_RESOURCES_DIR=<that>/ghostty` **before `ghostty_init`** (it captures the
dir at init). The server separately ships the compiled entries from
`packages/terminal/resources/terminfo` in both macOS's hexadecimal (`67/`,
`78/`) and Linux's first-character (`g/`, `x/`) lookup layouts; actual shell
PTYs use `TERM=xterm-ghostty` on macOS and `TERM=xterm-256color` on Linux,
alongside `COLORTERM=truecolor`. Only macOS receives
`TERMINFO=<bundled dir>`; Linux uses its system `xterm-256color` entry so the
Ghostty-only directory cannot mask standard entries in Zsh. When regenerating
the tarball after a Ghostty bump, also refresh the two canonical server-side
terminfo files from the same `zig-out/share` directory and copy them into the
Linux buckets so the renderer and advertised capabilities stay in sync.

## What's implemented

- **Workspace tabs and splits:** terminal panes share the workspace layout with
  chats, plugins, and documents. Open a New Tab and choose a terminal.
- **Focus routing:** selecting a terminal focuses its surface. Selecting a chat
  returns focus to that chat's composer; tab and split shortcuts follow the
  active pane.
- **Persistent terminal sessions:** pane models retain live surfaces while tabs
  and workspaces change, and server-owned shells can be reattached.

The terminal backend is selected at launch via `TerminalRuntime`, and the only
supported backend is the real libghostty surface.

## Architecture (since the vendoring)

The surface/input layer is **upstream Ghostty's own Swift code**, vendored at
the same commit as the xcframework — see
`Codevisor/Vendor/GhosttySwift/UPSTREAM.md` for the manifest, patch inventory,
and re-sync workflow (`scripts/sync-ghostty-swift.sh`). This provides the full
input stack: NSTextInputClient/IME + marked text, `performKeyEquivalent`
(⌘V paste, ⌘C copy), correct key encoding (`consumed_mods`,
`unshifted_codepoint`, kitty keyboard protocol), mouse tracking areas
(selection anchoring, hover), `viewDidChangeBackingProperties` (multi-DPI),
clipboard read/write callbacks with paste protection, and secure-input handling.

Codevisor-owned pieces in this directory:

- `CodevisorGhosttyApp.swift` — process-wide runtime host (replaces upstream's
  `Ghostty.App`): owns `ghostty_app_t` + themed `Ghostty.Config`, implements the
  clipboard/wakeup callbacks and a per-surface `action_cb` subset; window/tab/
  split actions are unhandled by design.
- `GhosttyTerminalSurface.swift` — implements `TerminalSurface` by
  wrapping the vendored `Ghostty.SurfaceView`; maps `TerminalLaunchDescriptor`
  to a host-managed `Ghostty.SurfaceConfiguration`: no local process runs;
  `TerminalController` (CodevisorCore) streams the server PTY into the surface
  and `GhosttyHostIO` returns its input and size.

## Rebuilding the terminal

1. **Fetch the framework**: `apps/macos/scripts/build-ghostty.sh` (seconds; no
   Zig or Metal toolchain needed). To move to a newer Ghostty, update its pins
   to a newer libghostty-spm `upstream.<ref>` release.

2. **Keep it linked into the app target** through the Xcode build settings or
   release-script overrides: `SWIFT_INCLUDE_PATHS` must point at the GhosttyKit
   headers and `OTHER_LDFLAGS` must force-load `libghostty-internal-fat.a`.

3. Build & run. If GhosttyKit or the bundled resources are missing, fix the
   packaging issue instead of shipping a degraded terminal.

### SDK caveat (why it isn't built here)

Ghostty's `build.zig` hard-requires **Zig 0.15.2**, but Zig 0.15.2 cannot link
native arm64 binaries against the **macOS 26/27 beta SDK** (its `libSystem.tbd`
only exposes `arm64e`/`x86_64`, not plain `arm64`). Zig 0.16 links fine but is
rejected by Ghostty's build. Build the framework on a machine with a **released**
macOS SDK (or once toolchain support lands), then drop the xcframework in.

## Notes / future work

- Not vendored (candidates for later): `SurfaceScrollView` (native scrollbar
  overlay), child-exited message bar, URL-hover banner, terminal inspector UI.
