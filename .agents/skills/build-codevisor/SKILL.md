---
name: build-codevisor
description: Build the Codevisor macOS or iOS app locally. Use when asked to build, compile, or verify either native app without launching it.
---

# Build Codevisor

Run from the worktree root:

```sh
bun run build:macos
bun run build:ios
```

Both commands install locked dependencies automatically and keep all Xcode output under `tmp/build/`. Do not invoke `xcodebuild` directly.

The macOS command fetches the pinned GhosttyKit artifact into `~/.codevisor-development/artifacts/ghostty/` and the pinned Chromium/CEF SDK plus its wrapper library into `~/.codevisor-development/artifacts/chromium/`, then links both into the worktree. These roots are shared by every worktree on the same pinned version; a lock file serializes concurrent first-time provisioning.

To keep each worktree small, version-pinned inputs that would otherwise be copied into every worktree also live once under `~/.codevisor-development/artifacts/` and reach the worktree as APFS clones, which share disk blocks until written: the bun install cache (`bun-cache/`), SwiftPM's unpacked binary artifacts such as WebRTC and Sentry (`swift-artifacts/`, swapped in right after package resolution by `scripts/swift-artifacts.mjs`), and the signed Debug Chromium framework (`chromium/signed-frameworks/`). Swift artifact and Chromium entries unused for 30 days are pruned; the bun cache, like bun's default global cache, is not. Measure a worktree's real cost with private (unshared) bytes, not `du`, which counts every clone in full. Only when intentionally rebuilding GhosttyKit itself, run:

```sh
bun run ghostty:build
```
