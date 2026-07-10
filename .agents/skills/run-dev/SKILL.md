---
name: run-dev
description: Start the HerdMan development server and build/run the native macOS app for local testing. Use when asked to run, launch, or test the dev app or server.
---

# Run the HerdMan dev app/server

From the repository worktree root, run:

```sh
bun run dev
```

This is the canonical development command. It:

- derives a stable identity and preferred port from the current worktree;
- builds the TypeScript server and native Swift app;
- uses worktree-local `DerivedData`;
- launches `HerdMan (<worktree-name>)` with an isolated database and Application Support directory;
- owns both processes and stops the server when the app exits or the command is interrupted.

Do not start the development server by itself. The app and server are one development instance and must receive the same port and data configuration.

Set `HERDMAN_DEV_PORT` only when a specific port is required. Ordinarily the runner selects a deterministic available port automatically.

## Rules

- Never `xcodebuild` a shared main checkout that other agent sessions may be editing. Run from your own git worktree; the development command uses that worktree's ignored `DerivedData` directory.
- Stop a running development instance through its owning `bun run dev` process. Do not kill arbitrary listeners by port.
- Other targets remain separate: `bun run dev:web` runs the public website and `bun run dev:desktop` runs the Tauri parity app.
