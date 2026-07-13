# Session Terminal (libghostty)

Each session has a terminal panel docked at the bottom of the session page,
scoped to the session's working directory.

> **Status: live.** `GhosttyKit.xcframework` is built and linked, so the panel
> runs a real libghostty terminal. The framework and runtime resources are
> required build inputs; missing Ghostty assets should fail the build.

## How GhosttyKit was built & linked (for rebuilds)

1. Build the static-lib xcframework (needs Zig 0.15.2 + the Metal Toolchain).
   Ghostty's required Zig 0.15.2 can't link against the macOS 26/27 *beta* SDK,
   so force a stable SDK that has an `arm64` slice via an `xcrun` shim:
   ```sh
   xcodebuild -downloadComponent MetalToolchain   # one-time
   # shim: make `xcrun --show-sdk-path` return a stable arm64 SDK
   #   e.g. /Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk
   cd .repos/ghostty
   zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
   # → .repos/ghostty/macos/GhosttyKit.xcframework ; copied to repo Frameworks/
   ```
2. Linked into the Codevisor target via build settings:
   - `SWIFT_INCLUDE_PATHS` points at the GhosttyKit macOS slice headers.
   - `OTHER_LDFLAGS = -force_load .../libghostty-internal-fat.a -lc++` + Metal,
     MetalKit, QuartzCore, CoreText, CoreGraphics, CoreVideo, IOSurface, IOKit,
     Carbon, AppKit, Foundation, CoreFoundation, Security, ApplicationServices,
     AudioToolbox, UniformTypeIdentifiers, GameController, Combine.

`CodevisorGhosttyApp` writes a temp config with `font-family = Menlo` and the app's
terminal font size so the renderer has a font even though Ghostty's bundled
JetBrains Mono isn't shipped (otherwise `ghostty_surface_new` fails), and so the
embedded terminal scale matches the rest of the app chrome.

**Resources:** the `xterm-ghostty` terminfo + shell-integration are bundled as
`Codevisor/Resources/ghostty-resources.tar.gz` (layout: `ghostty/shell-integration`
+ `terminfo/{67,78}`). On first launch `CodevisorGhosttyApp` extracts it to
`~/Library/Application Support/Codevisor/ghostty-resources/` and sets
`GHOSTTY_RESOURCES_DIR=<that>/ghostty` **before `ghostty_init`** (it captures the
dir at init). libghostty then sets `TERM=xterm-ghostty` and injects zsh/bash/etc.
shell integration. To regenerate the tarball after a Ghostty bump:
`cd .repos/ghostty/zig-out/share && tar czf <repo>/Codevisor/Resources/ghostty-resources.tar.gz ghostty/shell-integration terminfo`.

## What's implemented

- **Panel** at the bottom that pushes the chat + composer up, with a drag-to-resize
  handle and a header (title, cwd, close).
- **Toolbar toggle** (top-right of the session top bar) and **⌘J** to toggle.
- **Focus handoff**: ⌘J / toggle opens the panel and focuses the terminal; toggling
  again closes it and returns focus to the composer.
- **Per-session, persistent**: one terminal per session, cached in `SessionStore`.
  The surface (and its shell/scrollback) survives closing the panel and navigating
  to other sessions and back.

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
- `GhosttyTerminalSurfaceAdapter.swift` — implements `TerminalSurface` by
  wrapping the vendored `Ghostty.SurfaceView`; maps `TerminalLaunchDescriptor`
  (cwd + codevisor-terminal-proxy command) to `Ghostty.SurfaceConfiguration`.

## Rebuilding the terminal

1. **Build the framework** (needs Zig 0.15.2 and a *stable* macOS SDK — see the
   caveat below):

   ```sh
   scripts/build-ghostty.sh
   ```

   This produces `Codevisor/Frameworks/GhosttyKit.xcframework`.

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

- One terminal per session for now.
- Not vendored (candidates for later): `SurfaceScrollView` (native scrollbar
  overlay), child-exited message bar, URL-hover banner, terminal inspector UI.
- Bundle `codevisor-terminal-proxy` inside the .app so the terminal works without
  node/Homebrew on the user's machine (see `TerminalProxyCommand`).
