# GhosttyTerminal (vendored)

The iOS app's terminal view: libghostty-spm's `GhosttyTerminal` UIKit layer
(https://github.com/Lakr233/libghostty-spm, MIT — `LICENSE-libghostty-spm`),
vendored at commit `408c0616d2535f82d5e87535556715247b4aefca` (tag
`upstream.b40acce58dcf`), the same release `apps/macos/scripts/build-ghostty.sh`
takes GhosttyKit from. Surfaces run in libghostty's host-managed I/O mode; the
app feeds them the server's PTY stream through `InMemoryTerminalSession`.

Copied from `Sources/GhosttyTerminal` without `Platform/AppKit` (the macOS app
uses the vendored upstream AppKit layer) and `Resources` (shell integration and
terminfo only serve the exec backend, which Codevisor doesn't use).

Local changes, each marked `CODEVISOR-PATCH`:

- `InMemoryTerminalSession.receiveReplay(_:)` and replay-aware writes in
  `InMemoryTerminalSurfaceAccess`: history goes through
  `ghostty_surface_write_buffer_replay`, so queries in it aren't answered again.
- `Codevisor/DisplayLink.swift` replaces the MSDisplayLink dependency with a
  CADisplayLink.
- `GhosttyRuntimeResources` returns no resource directories.
- `TerminalSurface.imePoint()` is public and `TerminalSurface.cellPixelSize()`
  is added, to place the app's local-echo overlay and follow the cursor.

To update: copy the same directories from a newer libghostty-spm commit that
matches the GhosttyKit pin, then re-apply the marked patches.
