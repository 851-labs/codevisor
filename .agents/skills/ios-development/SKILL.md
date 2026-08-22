---
name: ios-development
description: Develop and test the Codevisor iOS app with Xcode and the iOS Simulator. Use when working on iOS code, launching or interacting with the simulator, inspecting the running iOS app, debugging simulator behavior, or verifying an iOS change.
---

# iOS Development

Open the iOS project in Xcode before trying to use Xcode's MCP tools. From the worktree root, run:

```sh
xed apps/ios/Codevisor.xcodeproj
```

Wait for Xcode to open and load the project. Then prefer the Xcode MCP for building, running, inspecting, and driving the app in the iOS Simulator.

Keep simulator work in the Xcode MCP instead of trying several overlapping tools. Do not start with `xcrun simctl`, direct `xcodebuild` commands, generic computer-use automation, or separate screenshot/accessibility tools when the Xcode MCP can perform the operation.

Use another tool only when the Xcode MCP is unavailable or lacks the required capability. Keep any fallback narrow, and state why it is needed before using it.
