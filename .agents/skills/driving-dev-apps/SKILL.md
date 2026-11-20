---
name: driving-dev-apps
description: Use when interacting with, inspecting, or capturing a running Codevisor dev app - clicking or typing in the macOS dev app, tapping, typing, or swiping in the iOS simulator, getting past onboarding, reading what is on screen, debugging simulator behavior, or taking a screenshot or screen recording of the app as evidence. Use before writing a window-id finder, an accessibility dump, an input-event injector, or any other helper to drive or capture the app.
---

# Driving and capturing the dev apps

The tools below already cover interaction and capture, so there is nothing to
compile. Start the apps with the `running-dev` skill first; it owns builds,
launch, and the simulator's lifecycle.

| Target                     | Interact                         | Screenshot                                   | Recording                                       |
| -------------------------- | -------------------------------- | -------------------------------------------- | ----------------------------------------------- |
| macOS dev app              | Codevisor's `computer-use` skill | `screencapture -x -o -l <windowId> shot.png` | `app.startRecording()` in Computer Use          |
| iOS simulator              | `axe … --udid <udid>`            | `xcrun simctl io <udid> screenshot shot.png` | `xcrun simctl io <udid> recordVideo … clip.mov` |
| Website, mascot playground | Codevisor's `browser-use` skill  | `tab.screenshot()` in Browser Use            | not needed                                      |

`computer-use`, `browser-use`, and `attaching-files` are Codevisor's built-in
skills: read them by calling Codevisor's `skills` tool with the skill's name.
They are not in the harness's own skill list.

## Capture only the window

Every screenshot or recording shows just the app window or the simulator
screen, never the whole display. Whole-screen captures pull in unrelated
windows and private content. When a flow spans two windows, send one capture
per window. Look at each capture before you cite it, then share it by
following the `attaching-files` skill; saving a file sends nothing. The
examples below write to `tmp/evidence`, which is ignored by git; create it
first with `mkdir -p tmp/evidence`.

## macOS dev app

- **Open the right app.** Pass the dev app's path to Computer Use so you get
  this worktree's build and not the released Codevisor:
  `computer.getApp("<worktree>/tmp/build/macos/DerivedData/Build/Products/Debug/Codevisor (<worktree name>).app")`.
- **Interact** through Computer Use (observe, click, type, wait). Do not
  drive the app with `osascript`, System Events, or a home-made event
  injector.
- **Screenshot a window to a file.** `computer.listRecordingTargets()` lists
  every window with its `windowId`, `app` (bundle identifier), `appName`,
  `title`, and size. The dev app's bundle identifier is
  `com.851labs.Codevisor.Development.<hash>`, where the hash is the folder
  name after `instances/` in the runner banner's `worktrees:` line, and its
  name is `Codevisor (<worktree name>)`. The `windowId` is the id
  `screencapture` takes:

  ```sh
  screencapture -x -o -l <windowId> tmp/evidence/after.png
  ```

  `-l` captures that window only, `-o` drops the shadow, `-x` is silent. If
  the image comes out empty, the window is minimized or on another Space;
  bring it back with `app.windowAction("restore")` or `"raise"` and capture
  again.

- **Record** an interaction with `app.startRecording()` and
  `recording.stop()`; the result includes ready-to-use Markdown for your
  reply.

## iOS simulator

Address the device by UDID in every command, so you can only ever touch this
worktree's simulator:

```sh
UDID=$(jq -r .udid tmp/runtime/ios-simulator.json)
```

Shell variables do not survive between tool calls, so read it again in each
one.

- **Read the screen:** `axe describe-ui --udid "$UDID"` prints the
  accessibility tree with labels, identifiers, and frames in points.
- **Tap:** `axe tap --udid "$UDID" --label "Continue"`, `--id <identifier>`,
  or `-x <x> -y <y>` in points. When a tap is delivered but nothing happens
  (list rows and menus do this), repeat it with `--tap-style physical`.
- **Type, swipe, long-press:** `axe type "text" --udid "$UDID"`,
  `axe swipe --start-x … --start-y … --end-x … --end-y … --udid "$UDID"`,
  and `axe touch -x … -y … --down --up --delay 1.2 --udid "$UDID"`.
  `axe <subcommand> --help` lists the rest.
- **Screenshot:** `xcrun simctl io "$UDID" screenshot tmp/evidence/ios.png`.
- **Record:** start
  `xcrun simctl io "$UDID" recordVideo --codec h264 tmp/evidence/ios.mov` in
  the background, perform the interaction, then send that process `SIGINT`
  (by its PID) so the file is finalized. The last few frames can be missing,
  so confirm the end state with a screenshot.

`axe` is a Homebrew tool (`brew install cameroncooke/axe/axe`), not something
the repo installs. When it is missing, or for an operation it lacks, use the
Xcode MCP's device tools through Codevisor's `execute` tool
(`machines.current.tools.search({ query: "DeviceInteraction" })`). They act
on Xcode's active project and run destination, so first read the `Xcode:`
line of the simulator's ready block (`running-dev` explains it) to see
whether the project window is open, then check the project and destination
match this worktree and its UDID before sending input. Do not use the Xcode
MCP's build or run tools.

After any input, look at the screen again; a delivered tap does not prove the
app reacted. Never quit Simulator, DeviceHub, or Xcode to recover; restart the
dev runner instead.

## Getting past a fresh install

A fresh dev instance signs into the development account by itself on its
first launch (`running-dev` explains when), so the other dev machines are
listed without a sign-in step. When the app is signed out, because it was
signed out or its data was deleted, it opens in onboarding; when the change
is not about onboarding, sign in with "Use Development Account". Choose
"Set Up Later" on every step that offers it, and start chats with "No
project" unless the change needs a specific project.

## Marketing screenshots are a different thing

`bun run screenshots:macos`, `screenshots:macos:direct`, `screenshots:ios`,
`screenshots:ios:direct`, and `screenshots:ios:app-store` produce website and
App Store images from demo data with their own builds. They are the only
scripts that drive a simulator themselves: `screenshots:ios:app-store`
captures every App Store device and writes the plain and framed upload sets,
on top of `screenshots:ios:direct` (one device) and `screenshots:ios` (UI
automation). Do not use them as evidence for a change.

## Common mistakes

- Compiling a Swift helper to find a window id, dump accessibility, or post
  events. Computer Use and `axe` already do these.
- Capturing the whole display.
- Opening "Codevisor" by name and driving the released app instead of the
  worktree's dev app.
- Tapping in DeviceHub or the Simulator window with Computer Use instead of
  addressing the device by UDID.
