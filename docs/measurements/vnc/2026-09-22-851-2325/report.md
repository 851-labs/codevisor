# 851-2325: pinned Xvnc container and `bun run vnc:interop` — validation

Machine: Apple M4 Max, macOS 27.2, AC power, OrbStack (Docker 29.4, arm64).
Base: `44378ea7`.

| Layer          | Result                                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------------------------- |
| L1 (scripts)   | `scripts/vnc-interop-lib.test.mjs`: 5 tests pass (arguments, image tag, port parsing, environment, the gate's verdict) |
| L3 (real Xvnc) | `bun run vnc:interop`: PASS — 3 tests ran, 0 skipped, 0.07 s; TigerVNC 1.15.0 (Debian trixie, pinned by digest)        |
| L3 negative    | `bun run vnc:interop --filter NoSuchInteropTests`: FAIL "no interop tests ran", exit 1                                 |
| Cleanup        | The container is removed after every run, including failed ones (`docker ps` shows none of ours)                       |
| L1/L2 (full)   | Full Swift suite via the pre-commit hook                                                                               |
| Benchmark / L4 | Not applicable: test infrastructure only                                                                               |

## What the gate checked

- Handshake RFB 003.008 with VNC authentication; desktop "codevisor-interop",
  1024 × 768 as configured.
- `theDesktopArrivesExactlyAsTheServerConfiguredIt` (new): the first update's
  centre pixel is exactly the configured root colour #336699
  (blue 153, green 102, red 51), and the size matches `VNC_TEST_GEOMETRY`.
- `VNCSessionInteropTests.framesReachTheMailbox`: a 1024 × 768 BGRA frame
  reaches the mailbox; 12 ZRLE rectangles, 304 bytes on the wire.

## Acceptance criteria

- **Pinned container:** `scripts/vnc-interop/` — Debian trixie by digest,
  `tigervnc-standalone-server=1.15.0+dfsg-2.1~deb13u1`, xdotool and xclip for
  later feature tests, VNC authentication, solid root colour.
- **`bun run vnc:interop`:** builds or reuses the image (tag follows the build
  context), runs it on an OS-chosen loopback port, waits for the RFB greeting,
  runs the Swift `InteropTests` suites with `VNC_TEST_*`, always removes the
  container, and exits non-zero unless tests ran, none were skipped and all
  passed. `--filter`, `--geometry`, `--keep`.
- **Faster suite:** `RFBInteropTests` stops at the first update instead of
  waiting out a 15 s deadline on a static desktop (15.6 s → 0.07 s).
- x11vnc as a second server: not added; noted as optional in the issue.

## Found while validating

- A stale `CodevisorCoreTests.cstemp` (interrupted code signing) in
  `packages/swift/.build` made `swift test` fail at CodeSign; deleting it fixed
  the build. Not a repository change.

## Metric target

None (scaffolding).
