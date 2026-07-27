---
name: run-dev
description: Start the Codevisor development server and build/run the native macOS or iOS app for local testing. Use when asked to run, launch, or test the dev app, dev server, or iOS simulator app.
---

# Run the Codevisor dev app/server

From the repository worktree root, run:

```sh
bun run dev
```

This is the canonical development command. It:

- derives a stable identity and preferred port from the current worktree;
- builds the TypeScript server and native Swift app;
- uses worktree-local `DerivedData`;
- launches `Codevisor (<worktree-name>)` with an isolated database and Application Support directory;
- owns both processes and stops the server when the app exits or the command is interrupted.

Do not start the development server by itself. The app and server are one development instance and must receive the same port and data configuration.

Set `CODEVISOR_DEV_PORT` only when a specific port is required. Ordinarily the runner selects a deterministic available port automatically.

## iOS app on the simulator

From the repository worktree root, run:

```sh
bun run dev:ios
```

This is the canonical iOS development command. It:

- starts the worktree's Dev Remote server (the same identity, port, token, and database `bun run dev` uses for its dev remote — the iOS app is a pure client of it);
- builds the iOS app with a worktree-scoped bundle identifier, `Codevisor (<worktree-name>)` display name, and a worktree-colored dev icon;
- installs and launches it on the simulator (default "iPhone 17 Pro"; override with `CODEVISOR_IOS_SIMULATOR=<device name>` from `xcrun simctl list devices available`);
- passes the dev remote's coordinates in the launch environment, so the app pairs with the machine automatically on first boot;
- owns the server process and stops it when the command is interrupted.

### iOS-specific rules

- `bun run dev` and `bun run dev:ios` share one dev-remote identity and port per worktree, and each spawns its own server — never run both at once. Stop the one you own and wait for its server to exit (`/v1/health` stops responding) before starting the other. The already-installed simulator app keeps working against whichever runner currently hosts the shared remote.
- After changing iOS app code (or shared package code) while an instance you started is running, restart cleanly: stop the owning `bun run dev:ios` process, wait for the server to exit, then run `bun run dev:ios` once to rebuild, reinstall, and relaunch.
- The simulator keeps the app installed between runs; only the runner's rebuild/reinstall updates it. Launching the stale app icon by hand runs old code against no server — always go through the runner.
- All macOS ownership rules below apply equally to iOS instances: one per worktree, track the owning process, never touch other worktrees' instances or kill listeners by port.

## Rules

- Never `xcodebuild` a shared main checkout that other agent sessions may be editing. Run from your own git worktree; the development command uses that worktree's ignored `DerivedData` directory.
- Keep at most one `bun run dev` instance running for the current worktree. Before starting one, check whether this worktree already has a live instance. Reuse an instance you started when it is still current; never start a second instance on another port.
- Track the owning `bun run dev` process for every instance you start. Stop that parent process and wait for its app and server children to exit before starting a replacement. Do not kill arbitrary listeners by port, process name, or broad process matching.
- Treat every other worktree's development instance as out of scope. Never stop, restart, signal, or otherwise alter it unless the user explicitly asks you to operate on that specific worktree. A port occupied by another worktree is not permission to touch it; let the runner select another port.
- If the current worktree already has an instance that you did not start, do not launch another one. Reuse it when appropriate or tell the user it is already running; do not stop it unless its ownership is clear or the user asks you to replace it.
- After changing the native macOS app while an instance you started is running, restart cleanly: stop the owning `bun run dev` process, wait for the server to exit, then run `bun run dev` once to rebuild and relaunch. Never leave the old server running and start an additional development command.
- Other targets remain separate: `bun run dev:web` runs the public website and `bun run dev:desktop` runs the Tauri parity app.
