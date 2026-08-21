---
name: run-dev
description: Start the Codevisor development server and build/run the native macOS or iOS app for local testing. Use when asked to run, launch, or test the dev app, dev server, or iOS simulator app.
---

# Run Codevisor

From the worktree root, use exactly one of:

```sh
bun run dev
bun run dev:ios
```

The runners install locked dependencies, resolve GhosttyKit when needed, and keep build/runtime state under the worktree's ignored `tmp/`. Do not run `bun install`, `xcodebuild`, the server, or Ghostty build scripts separately.

`dev:ios` uses the visible `iPhone 17 Pro` simulator by default. Set `CODEVISOR_IOS_SIMULATOR=<device name>` to select another available simulator. Its stable development bundle identifier replaces the previous dev install instead of accumulating one app per worktree.

Keep at most one runner active per worktree. Track and stop the parent process you started before rebuilding. Never stop or modify another worktree's instance; if this worktree already has an instance you do not own, reuse it or report that it is running.

For website-only development, use `bun run dev:web`.
