---
name: ios-development
description: Develop and test the Codevisor iOS app with Xcode and the iOS Simulator. Use when working on iOS code, launching or interacting with the simulator, inspecting the running iOS app, debugging simulator behavior, or verifying an iOS change.
---

# iOS Development

From the worktree root, start the simulator owner as a persistent background task:

```sh
bun run ios-simulator
```

Wait for `Simulator ready`, then start `bun run dev:ios` (iOS only) or `bun run dev` (iOS and macOS) in another background task. The simulator script creates a dedicated device, boots it, opens this worktree's project in Xcode, and opens Simulator or DeviceHub. The dev runner builds, installs, and launches the app on that exact device. Follow [run-dev](../run-dev/SKILL.md) for runner lifecycle.

Use `bun run ios-simulator --device="iPhone 17" --runtime=27.0` to select an installed device type and runtime. Omit `--runtime` for the newest compatible installed iOS runtime. Select the printed worktree device in DeviceHub if another device is currently selected. Do not use a shared default iPhone or manually create another device.

Read `tmp/runtime/ios-simulator.json` for the owned device UUID. Keep the simulator task running across dev-server restarts. Stopping the simulator task shuts down and deletes that device; its data lives in CoreSimulator's default location so DeviceHub can discover it. The owner also watches launcher death and worktree deletion. A later launch recovers marked orphan devices after an owner crash.

Tests never need a simulator: `bun run check` and the pre-commit hook run only host unit tests and an iOS build. Only `bun run screenshots:ios`, which captures App Store screenshots through UI automation, drives a simulator.

Once the scripts finish startup, prefer Xcode MCP for inspecting and driving the app. Check that its project and destination match this worktree and the printed UUID. Use the dev runner to rebuild and reinstall so its worktree configuration is preserved.

Keep app inspection and interaction in Xcode MCP when it supports the operation. The repo scripts own simulator lifecycle, project opening, builds, installation, and launch.

Use another tool only when the Xcode MCP is unavailable or lacks the required capability. Keep any fallback narrow, and state why it is needed before using it.
