# Vendored Ghostty Swift Surface Layer

Upstream Ghostty's macOS surface/input layer, vendored so Codevisor's terminal
gets the full battle-tested AppKit embedding (NSTextInputClient/IME,
`performKeyEquivalent`, mouse tracking areas, clipboard callbacks, DPI
handling) instead of a hand-rolled reimplementation.

- **Upstream**: https://github.com/ghostty-org/ghostty (MIT — see `LICENSE`)
- **Pinned commit**: `28f9367bee11ad42f40f8aa589eb8c6db62d34be`
  (must match `GHOSTTY_REF` in `apps/macos/scripts/build-ghostty.sh` — the
  Swift layer and the GhosttyKit.xcframework MUST always be built from the
  same commit; the libghostty C API is explicitly unstable)
- **Source root**: `.repos/ghostty/macos/Sources/`

## Layout

| Vendor path | Upstream path |
|---|---|
| `Ghostty/*.swift` | `Sources/Ghostty/*.swift` |
| `Ghostty/Surface View/{OSSurfaceView,SurfaceView_AppKit}.swift` | `Sources/Ghostty/Surface View/…` |
| `Ghostty/Surface View/SurfaceConfiguration.swift` | **extraction** — `struct SurfaceConfiguration` (SurfaceView.swift L627-752) + `Ghostty.moveFocus` (L1136-1190) |
| `Helpers/**` | `Sources/Helpers/**` |
| `Features/SecureInput.swift` | `Sources/Features/Secure Input/SecureInput.swift` |

Deliberately **not** vendored: `Ghostty.App.swift` (its runtime-host role is
rewritten as `Features/Terminal/CodevisorGhosttyApp.swift`), the SwiftUI wrapper
layer (`SurfaceView.swift`, scrollbar/progress/inspector/drag UI), and anything
depending on Ghostty.app's windows/tabs/splits/AppDelegate.

## Patches

Every deviation from upstream is wrapped in `CODEVISOR-PATCH-BEGIN/END` markers
(or a single-line `CODEVISOR-PATCH:` note for deletions). Find them all:

```sh
grep -rn "CODEVISOR-PATCH" apps/macos/Codevisor/Vendor/GhosttySwift
```

Patch classes (12 files):
1. **Explicit imports** (`Foundation`, `AppKit`, `Combine`, `os`, `SwiftUI`) —
   Codevisor builds with `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`;
   upstream gets these transitively. (Ghostty.Shell, Ghostty.Error,
   Ghostty.Config, OSSurfaceView, SurfaceView_AppKit, OSColor+, OSPasteboard+,
   NSAppearance+, SecureInput)
2. **App-coupled code removed** — `SplitTree` conversion (GhosttyPackage),
   quick-terminal + fullscreen-mode config accessors (Ghostty.Config),
   AppDelegate/BaseTerminalController touchpoints, focus-follows-mouse,
   command-palette guard, split menu items + IBActions, window-restoration
   `Codable` support (SurfaceView_AppKit), `AppDelegate.logger → Ghostty.logger`
   (14 sites in SurfaceView_AppKit, 2 in OSSurfaceView).
3. **AppEnum/App Intents removed** (Ghostty.Input) — conflicts with Codevisor's
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `Key.allCases` preserved since
   `Key.init?(keyCode:)` depends on it.

## Re-syncing to a new upstream commit

1. Update `GHOSTTY_REF` in `apps/macos/scripts/build-ghostty.sh`; run it to
   rebuild `Frameworks/GhosttyKit.xcframework` (needs Zig 0.15.2).
2. Run `apps/macos/scripts/sync-ghostty-swift.sh` — copies the manifest files
   from `.repos/ghostty` over this directory and prints the diff.
3. Re-apply the patches: `git diff` will show upstream's changes mixed with
   reverted CODEVISOR-PATCH blocks; restore each marked patch (grep above).
4. Build; new `MemberImportVisibility` or isolation errors mean new patch-class-1
   entries.
5. Verify per `apps/macos/Codevisor/Features/Terminal/README.md`.
