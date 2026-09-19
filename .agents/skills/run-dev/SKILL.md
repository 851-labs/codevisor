---
name: run-dev
description: Start the Codevisor development server and build/run the native macOS or iOS app for local testing. Use when asked to run, launch, or test the dev app, dev server, or iOS simulator app.
---

# Run Codevisor

From the worktree root, use exactly one of:

```sh
bun run dev
bun run dev:macos
bun run dev:ios
```

The runners install locked dependencies, resolve the shared GhosttyKit and Chromium/CEF artifacts (version-pinned, under `~/.codevisor-development/artifacts/`), and keep all other build/runtime state under the worktree's ignored `tmp/`. Do not run `bun install`, `xcodebuild`, the server, or Ghostty build scripts separately.

Before `dev:ios` or `dev`, run `bun run ios-simulator` in a separate persistent background task and wait for `Simulator ready`. It creates this worktree's device and opens the project in Xcode and the simulator UI. The default device type is `iPhone 17 Pro`; select another installed type/runtime with `bun run ios-simulator --device="iPhone 17" --runtime=27.0`. Device selection belongs to this command. The dev runners fail early with a startup hint if the owner or its exact booted device is missing.

The simulator stays alive across dev-runner restarts. Stopping `ios-simulator` shuts down and deletes only its owned device and closes the exact Xcode project window it opened. An already-open project window is reused and left open. A separate window watcher survives launcher or simulator-owner `SIGKILL`; it retains the Accessibility window object and checks the Xcode process and full project path before closing it. It never quits Xcode or takes ownership of a replacement window. The terminal or app running this command needs macOS Accessibility access; startup fails explicitly if it is unavailable. Device files use CoreSimulator's default location for DeviceHub compatibility; the worktree's ownership manifest lives in `tmp/runtime/ios-simulator.json`. Do not manually boot, delete, or reuse another worktree's device.

`dev` builds and launches both native apps against one shared set of local, remote, and cloud development services. All three native runners start Dev Direct and Dev Cloud as Linux containers by default (Apple `container` preferred, Docker fallback). Each accepts `--containers`, `--no-containers`, and `--container-engine=apple|docker|none`; `--no-containers` and `--container-engine=none` run the remotes as same-host processes, also the fallback when no engine is available. `dev:macos` builds only macOS and needs no simulator; `dev:ios` builds only iOS.

Keep at most one dev runner and one simulator owner active per worktree. Track the tasks you start. Stop the dev runner and wait for cleanup before restarting it; leave the simulator owner running. Prefer `SIGTERM` or stopping the managed background task. A separate supervisor also handles launcher death, including `SIGKILL`, and removes the worktree's dev processes and externally launched app/container resources. Never stop another worktree's instance; reuse or report an existing task you do not own.

For a permission-grant restart that must preserve the existing signed macOS binary, use `bun run dev:macos --reuse-macos-build` (container flags still apply). This verifies the worktree app's identity and strict signature, skips native building/signing, and starts the usual managed services and app. It deliberately does not incorporate native source edits. Missing, mismatched, or invalid artifacts fail without falling back to a rebuild. Normal launches continue to build. This option is macOS-only.

For website-only development, use `bun run dev:web`.
