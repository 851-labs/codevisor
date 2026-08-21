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

The macOS command fetches the pinned GhosttyKit artifact into `~/.codevisor-development/artifacts/ghostty/` and links it into the worktree. Only when intentionally rebuilding GhosttyKit itself, run:

```sh
bun run ghostty:build
```
