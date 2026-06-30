# Session Terminal (libghostty)

Each session has a terminal panel docked at the bottom of the session page,
scoped to the session's working directory.

> **Status: live.** `GhosttyKit.xcframework` is built and linked, so the panel
> runs a real libghostty terminal. If the framework is ever removed, the code
> falls back to the placeholder automatically (`#if canImport(GhosttyKit)`).

## How GhosttyKit was built & linked (for rebuilds)

1. Build the static-lib xcframework (needs Zig 0.15.2 + the Metal Toolchain).
   Ghostty's required Zig 0.15.2 can't link against the macOS 26/27 *beta* SDK,
   so force a stable SDK that has an `arm64` slice via an `xcrun` shim:
   ```sh
   xcodebuild -downloadComponent MetalToolchain   # one-time
   # shim: make `xcrun --show-sdk-path` return a stable arm64 SDK
   #   e.g. /Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk
   cd references/ghostty
   zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
   # → references/ghostty/macos/GhosttyKit.xcframework ; copied to repo Frameworks/
   ```
2. Linked into the HerdMan target via build settings (pbxproj edits are blocked):
   - `SWIFT_INCLUDE_PATHS = $(SRCROOT)/Frameworks/GhosttyKit.xcframework/macos-arm64/Headers`
   - `OTHER_LDFLAGS = -force_load .../libghostty-internal-fat.a -lc++` + Metal,
     MetalKit, QuartzCore, CoreText, CoreGraphics, CoreVideo, IOSurface, IOKit,
     Carbon, AppKit, Foundation, CoreFoundation, Security, ApplicationServices,
     AudioToolbox, UniformTypeIdentifiers, GameController, Combine.

`GhosttyRuntime` writes a temp `font-family = Menlo` config so the renderer has a
font even though Ghostty's bundled JetBrains Mono isn't shipped (otherwise
`ghostty_surface_new` fails).

**Resources:** the `xterm-ghostty` terminfo + shell-integration are bundled as
`HerdMan/Resources/ghostty-resources.tar.gz` (layout: `ghostty/shell-integration`
+ `terminfo/{67,78}`). On first launch `GhosttyRuntime` extracts it to
`~/Library/Application Support/HerdMan/ghostty-resources/` and sets
`GHOSTTY_RESOURCES_DIR=<that>/ghostty` **before `ghostty_init`** (it captures the
dir at init). libghostty then sets `TERM=xterm-ghostty` and injects zsh/bash/etc.
shell integration. To regenerate the tarball after a Ghostty bump:
`cd references/ghostty/zig-out/share && tar czf <repo>/HerdMan/Resources/ghostty-resources.tar.gz ghostty/shell-integration terminfo`.

## What's implemented

- **Panel** at the bottom that pushes the chat + composer up, with a drag-to-resize
  handle and a header (title, cwd, close).
- **Toolbar toggle** (top-right of the session top bar) and **⌘J** to toggle.
- **Focus handoff**: ⌘J / toggle opens the panel and focuses the terminal; toggling
  again closes it and returns focus to the composer.
- **Per-session, persistent**: one terminal per session, cached in `SessionStore`.
  The surface (and its shell/scrollback) survives closing the panel and navigating
  to other sessions and back.

The terminal backend is selected at launch via `TerminalRuntime`:
- `#if canImport(GhosttyKit)` → real libghostty surface (`GhosttyTerminalSurface`).
- otherwise → a buildable `PlaceholderTerminalSurface` (a styled panel that names the
  cwd and explains how to enable the real terminal).

Everything is wired through the `TerminalSurface` protocol, so the real terminal
drops in unchanged once `GhosttyKit` is linked — no other code changes.

## Enabling the real terminal

1. **Build the framework** (needs Zig 0.15.2 and a *stable* macOS SDK — see the
   caveat below):

   ```sh
   scripts/build-ghostty.sh
   ```

   This produces `HerdMan/Frameworks/GhosttyKit.xcframework`.

2. **Link it into the app target** in Xcode (the project's source files are
   file-system-synchronized, but framework linking is a project setting and must be
   done in the Xcode UI):
   - Target *HerdMan* → *General* → *Frameworks, Libraries, and Embedded Content* →
     **+** → Add Other → add `HerdMan/Frameworks/GhosttyKit.xcframework` →
     *Embed & Sign*.
   - The module map in the xcframework exposes `import GhosttyKit`. Once it links,
     `canImport(GhosttyKit)` flips on and `GhosttyTerminalSurface` is compiled.

3. Build & run. The placeholder is replaced by a live shell in the session's cwd.

### SDK caveat (why it isn't built here)

Ghostty's `build.zig` hard-requires **Zig 0.15.2**, but Zig 0.15.2 cannot link
native arm64 binaries against the **macOS 26/27 beta SDK** (its `libSystem.tbd`
only exposes `arm64e`/`x86_64`, not plain `arm64`). Zig 0.16 links fine but is
rejected by Ghostty's build. Build the framework on a machine with a **released**
macOS SDK (or once toolchain support lands), then drop the xcframework in.

## Notes / future work

- `GhosttyTerminalSurface` is a focused single-surface integration (lifecycle,
  render, focus, resize, keyboard/mouse). For full IME / marked-text fidelity,
  vendor Ghostty's `SurfaceView_AppKit` input layer
  (`references/ghostty/macos/Sources/Ghostty`).
- One terminal per session for now.
