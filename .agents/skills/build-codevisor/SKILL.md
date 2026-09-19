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

The macOS command fetches the pinned GhosttyKit artifact into `~/.codevisor-development/artifacts/ghostty/` and the pinned Chromium/CEF SDK plus its wrapper library into `~/.codevisor-development/artifacts/chromium/`, then links both into the worktree. These roots are shared by every worktree on the same pinned version; a lock file serializes concurrent first-time provisioning. Only when intentionally rebuilding GhosttyKit itself, run:

```sh
bun run ghostty:build
```
