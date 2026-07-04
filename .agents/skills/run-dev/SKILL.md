---
name: run-dev
description: Start the HerdMan development server and build/run the native macOS app for local testing. Use when asked to run, launch, or test the dev app or server.
---

# Run the HerdMan dev app/server

## Dev server

From the repo root:

```sh
bun run dev:server
```

Runs `apps/server` on port **49362** — the fixed dev port the macOS app connects to.

If a dev server is already running, kill it first so you don't test against stale server code:

```sh
lsof -ti :49362 | xargs kill
```

## macOS app

Interactive: open `apps/macos/HerdMan.xcodeproj` in Xcode and Run.

CLI:

```sh
bun run xcode:list   # list schemes
xcodebuild -project apps/macos/HerdMan.xcodeproj -scheme HerdMan \
  -derivedDataPath DerivedData build
```

The built app lands under `DerivedData/Build/Products/Debug/HerdMan.app`; launch it with `open`.

## Rules

- **Always pass `-derivedDataPath DerivedData`** (or `.derivedData`). Never invent variants like `.derived-data` — only those two names are gitignored.
- **Never `xcodebuild` a shared main checkout** that other agent sessions may be editing. Build from your own git worktree (or a scratch worktree with your diff applied) with a worktree-local `-derivedDataPath`, so untracked WIP files and DerivedData don't cross-contaminate builds.
- Other dev targets: `bun run dev:web` (web app), `bun run dev:desktop` (desktop app; builds `@herdman/server` first).
