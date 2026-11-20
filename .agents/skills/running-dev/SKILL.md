---
name: running-dev
description: Use when starting, restarting, stopping, or building Codevisor locally - the dev server, the macOS dev app, the iOS simulator app, the website, or the mascot playground. Use when asked to run, launch, build, compile, or check that an app builds; before reaching for xcodebuild, simctl, or bun install; when starting or choosing the iOS simulator; and when a dev runner looks hung, exits early, or will not start.
---

# Running Codevisor in development

Run everything from the worktree root through the repo's scripts. They install
locked dependencies, fetch the pinned native artifacts, call `xcodebuild`,
sign, start the servers, and launch the apps. Do not run `xcodebuild`, the
server, or the Ghostty build scripts yourself, and do not create or boot
simulators by hand.

## Pick a command

| Goal                                                  | Command                                    | Needs first                                      |
| ----------------------------------------------------- | ------------------------------------------ | ------------------------------------------------ |
| macOS app and its dev server                          | `bun run dev`                              | nothing                                          |
| macOS app and the iOS app, signed into one account    | `bun run dev:ios`                          | the simulator owner                              |
| macOS app and a Linux container as the remote machine | `bun run dev:linux`                        | Apple's `container`, OrbStack, or Docker Desktop |
| Check that an app compiles, no launch                 | `bun run build:macos`, `bun run build:ios` | nothing                                          |
| Website only                                          | `bun run dev:web`                          | nothing                                          |
| Bot mascot package in a browser                       | `bun run dev:mascot-playground`            | nothing                                          |

`bun run dev` is the everyday command. Use `dev:ios` when the change touches
the iOS app or something you check from a second device; it exits at once
with "This worktree's simulator must already be running" until the simulator
owner is up (see [iOS simulator](#ios-simulator)). Use `dev:linux` only when
the change touches the Linux server, sandboxes, or containers; see
[The Linux container](#the-linux-container-devlinux). None of them starts a
container unless it is `dev:linux`.

## Before you start

- **Node on PATH.** The runner starts the server with `node` (the version in
  `.node-version`). Check `command -v node`. Some agent shells have none: on
  Homebrew, Node is keg-only, so prefix the command with
  `PATH="/opt/homebrew/opt/node@24/bin:$PATH"`. Without Node the app builds,
  then the server dies with `'better-sqlite3' is not yet supported in Bun` and
  the runner exits. The same prefix fixes a commit hook that fails with
  `Cannot use test outside of the test runner`.
- **Longest background timeout.** Start the dev runner, and the simulator
  owner, as background tasks with your harness's longest timeout (Claude
  Code: `run_in_background` with `timeout: 7200000`; the default is 30
  minutes). When the limit is reached the harness kills the task: the runner
  takes the app and servers down with it, and the simulator owner deletes its
  device. Restart them when that happens, and say so in your report.
- **One runner per worktree.** Keep at most one dev runner and one simulator
  owner per worktree. A second one fails with "A Codevisor development runner
  is already active". Reuse a matching instance you started; report one you
  did not.

## Start it and wait until it is ready

The output is tens of thousands of lines of raw `xcodebuild` log, so send it
to a file and search the file. The usual start for a macOS change:

```sh
mkdir -p tmp && bun run dev > tmp/dev.log 2>&1
```

Then wait for a ready or failure line in a second background task:

```sh
until grep -qE "Codevisor dev is ready|xcodebuild failed|exited with code|exited unexpectedly|already active" tmp/dev.log; do sleep 5; done
grep -E "is listening on|Linux container|iOS is running|Codevisor dev is ready|error:|xcodebuild failed|exited" tmp/dev.log | tail
```

The runner prints these lines, in this order:

1. A banner with this instance's addresses: `server:` (the dev server),
   `www:`, `cloud:`, `data:`, `worktrees:`, `icon:`, `targets:`, and for
   `dev:linux` also `viacloud:` (Dev Cloud).
2. `Codevisor dev server is listening on http://127.0.0.1:<port>`.
3. `dev:linux` only: `Dev Cloud (<worktree>) is running in its Linux container.`
4. `dev:ios` only: `Codevisor iOS is running on <simulator> against the dev cloud:`.
5. `Codevisor dev is ready: <what started>.` The Mac app was opened just
   before this line. Nothing is printed when its window appears, so confirm
   the process with
   `pgrep -fl "$PWD/tmp/build/macos/.*Contents/MacOS/Codevisor"`, and its
   window with the window list in the `driving-dev-apps` skill.

After that the log keeps filling with server and harness-inspection messages;
they are not errors in your change.

Failure lines:

- `xcodebuild failed (code 65)`: a compile error. Find it with
  `grep -n "error:" tmp/dev.log`.
- `error: script "dev" exited with code 1` (or `dev:ios`, `dev:linux`): the
  runner stopped; the reason is a few lines above.
- `dev:linux runs its remote machine in a Linux container and found no
container engine`: install or start one of the engines it names; see
  [The Linux container](#the-linux-container-devlinux).
- `Codevisor server exited unexpectedly`: usually no Node on PATH.
- `Unknown development runner argument`: the runners take only
  `--reuse-macos-build`. There is no `--help`, and the old `--no-ios`,
  `--containers`, `--no-containers`, and `--container-engine` flags are gone.

### How long it takes

A first run in a fresh worktree does a full Xcode build, which measured
from 3 to 10 minutes on a 14-core Mac depending on how busy it was. Later
runs in the same worktree only rebuild what changed. `build:macos` and
`build:ios` pay the same first-run cost.

The Rust networking library is normally not part of that cost: every
worktree whose networking inputs match reuses one build per machine (see
[Shared artifacts and disk](#shared-artifacts-and-disk)), and the log says
so:

```
codevisor-net build:swift 10b9eff5159cdbb6: reusing the shared build
```

When no worktree on this Mac has built those inputs yet, the run compiles
the library for five Apple targets first, which measured 7 to 13 more
minutes. It prints a headline per target and a line every 20 seconds while
it works:

```
codevisor-net build:swift 10b9eff5159cdbb6: no shared build yet
==> Compiling for aarch64-apple-ios (3 of 5)
    Compiling for aarch64-apple-ios (3 of 5): 212 crates so far, 1m 40s
```

When another worktree is already building the same inputs, the run waits
for it instead of building a second copy, and prints
`another worktree is using it; waiting (1m 20s)` every 20 seconds until it
can reuse the result.

Before the ready lines appear, tell slow from stuck by checking whether the
build is still writing files:

```sh
find packages/net/target tmp/build -type f -mmin -2 2>/dev/null | head -3
```

Any output means it is working; leave it alone. `stat -f %Sm tmp/dev.log`
shows when the log last grew. When neither has changed for five minutes, stop
the runner, start it again, and report what the log's last lines were. The
check covers compiling only: the first run on a machine also downloads the
pinned artifacts into `~/.codevisor-development/artifacts/`, which it does
not see. Once the app is ready, a quiet log is normal.

## Flags

`--reuse-macos-build` is the only flag, and all three runners take it. It
relaunches the existing signed Mac app without building it; see
[Restart and stop](#restart-and-stop). The runners reject anything else,
including `xcodebuild` arguments; only `build:macos` and `build:ios` forward
those.

## Signing in

The apps sign into the local dev cloud's development account by themselves
the first time they launch in a fresh instance, so on `dev:ios` the iOS app
lists the Mac's machine, and on `dev:linux` the Mac app lists Dev Cloud,
with no sign-in step. "Fresh" means:

- the Mac app: once per worktree `tmp/`;
- the iOS app: once per simulator device, so a new simulator owner's device
  is signed in again.

After that it is ordinary sign-in: signing out, or deleting the app's data
(Delete app data on macOS, Delete Device Data on iOS), leaves the app signed
out across relaunches, so onboarding and the sign-in screens can be tested
from a clean state. "Use Development Account" signs back in. To have the
runner sign the apps in again, delete `tmp/runtime/sign-in` and restart the
runner. The runner records each offer there; it is not in the app's data, so
the app cannot undo it.

## The Linux container (`dev:linux`)

`dev:linux` runs the second machine, Dev Cloud, as a Linux server in one
container (4 CPUs, 4 GB). It signs into the dev cloud itself, the "already
signed in somewhere else" machine. It uses the first engine that works, in
this order, and prints the one it picked:

1. Apple's `container` (1.x; `brew install container`).
2. Docker, served by OrbStack (`brew install orbstack`) or Docker Desktop.

With none of them it stops with an error that names what to install. It
never runs Dev Cloud as a process on the Mac instead, because that is not
Linux. The first boot in a worktree installs Linux `node_modules` into
`tmp/container`, which takes a few minutes; later boots reuse it. The
container has an empty home folder, so no harness is installed or signed in
there.

With `CODEVISOR_DEV_CONTAINER_DESKTOP=1` the container also runs an Xfce
desktop over VNC (`scripts/dev-container-desktop.sh`), which the macOS app
opens as a Screen Sharing pane and Computer Use drives through AT-SPI. It is
off by default because its packages add a few seconds to every boot.

## Where things are

- **Mac app:** `tmp/build/macos/DerivedData/Build/Products/Debug/Codevisor (<worktree>).app`,
  named `Codevisor (<worktree>)` on screen.
- **iOS app:** `tmp/build/ios/DerivedData/Build/Products/Debug-iphonesimulator/Codevisor.app`.
- **Dev server:** the banner's `server:` address. `curl -s <address>/v1/health`
  answers when it is up. The port is derived from the worktree path; the
  next free one is used when it is taken, and the "is listening on" line has
  the real one.
- **Data and logs:** `tmp/.codevisor/data` (the server's database and data;
  the Mac app's own state, sign-in, and browser profiles are in its `Client`
  folder, which the app's "Delete app data" removes) and
  `tmp/.codevisor/logs/server.log`. With `dev:linux`, Dev Cloud's data is
  under `tmp/remote-cloud`, its Linux workspace under `tmp/container`, and
  its server log in `tmp/container/state/server.log`.
- **Folders agents work in** (worktrees, bots, and no-project chats the dev
  app creates): `~/.codevisor-development/instances/<worktree hash>/codevisor`,
  outside the repo, so an agent there never picks up this repo's `AGENTS.md`.
  A worktree that already has them in `tmp/codevisor` keeps using that
  folder.

Everything else the runners write stays under the worktree's ignored `tmp/`.

### What lives outside `tmp/`, and who removes it

A few things cannot live in the worktree. Each is keyed to the worktree by
the hash of its path, and `~/.codevisor-development/instances/<worktree hash>/repo-root`
records which worktree that is:

- `dev:linux` only: the Dev Cloud container, labelled
  `dev.codevisor.worktree=<worktree hash>`. Every folder it writes to is
  mounted from `tmp/`, but the container's own disk cannot be: Apple's
  `container` keeps it in its one data folder for the whole Mac,
  `~/Library/Application Support/com.apple.container/containers/<name>`
  (2.4 to 3 GB measured), and Docker and OrbStack keep it in their own VM disk. The
  container is started with `--rm`, so that disk is deleted as soon as the
  container stops, and Docker and OrbStack also delete its volumes. The
  `node:22-bookworm` image (about 1 GB) and the Linux bun cache
  (`~/.codevisor-development/artifacts/linux-bun-cache`) are shared by every
  worktree and stay;
- the instance folder above;
- what macOS keeps per app under `~/Library` (Preferences, Caches,
  HTTPStorages, WebKit, Application Support), in the per-user cache and temp
  folders, and in the keychain and privacy permissions, all named
  `com.851labs.Codevisor.Development.<worktree hash>`;
- the simulator device, named `Codevisor Worktree <worktree> (<worktree hash>)`.

They are removed in three ways, so deleting or archiving a worktree needs no
manual cleanup:

- The runner removes its container (and its disk) and stops its app when it stops, and the
  simulator owner deletes its device. Both run outside the process tree of
  the command that started them, so they still do this when that command, or
  the whole task, is killed with `SIGKILL`. A runner that stops because its
  worktree is gone also removes the instance folder and the `~/Library`
  state.
- The Dev Cloud container stops itself when the worktree's `tmp/` is
  deleted, even if no runner is left to remove it, and `--rm` then deletes
  its disk.
- Every dev runner start, in any worktree, cleans up after worktrees that no
  longer exist: their containers, processes still running from their folder,
  their `~/Library` state, and their instance folder. It prints
  `Cleaned up after the deleted worktree <path>` for each.

## Restart and stop

- **The runner lives as long as the Mac app.** Quitting the app, or a crash,
  stops the runner, the dev server, and Dev Cloud if it runs. Data in `tmp/`
  survives.
- **Pick up a code change:** stop the runner, wait for it to exit, start it
  again. It rebuilds what changed.
- **Relaunch without a native change** (after quitting the app, a crash, a
  permission grant that needs the same signed binary, or a server-only
  change): wait for the old runner to exit, then run
  the same runner again with `--reuse-macos-build`, for example
  `bun run dev --reuse-macos-build`. It verifies the app's identity and signature, skips native
  building and signing, and starts the usual services. It does not pick up
  Swift edits, and a missing or mismatched app fails with "Cannot reuse macOS
  build" instead of rebuilding.
- **`dev:ios` still builds the iOS app** with `--reuse-macos-build`; only
  the Mac build is skipped.
- **The dev server is never restarted on its own.** When it is stuck or
  needs new server code, restart the runner.
- **Stop:** stop the background task you started, or send `SIGTERM` to the
  runner, then wait for it to exit. This worktree's runner is the `bun`
  process that `pgrep -fl "$PWD/scripts/dev-owner.mjs"` prints (`kill <pid>`),
  and its simulator owner is the one
  `pgrep -fl "$PWD/scripts/ios-simulator-owner.mjs"` prints. `pgrep` also
  prints an `sh` line for each: the small shell that waits for the `bun`
  process, which is the one to signal. Cleanup takes a few seconds and
  removes this worktree's app, servers, and container. The same cleanup runs
  when the `bun run` command that started the runner dies, even when the
  whole task is killed with `SIGKILL`.
- Never stop another worktree's instance, and never stop processes by
  pattern (`pkill`, `killall`, `kill $(pgrep …)`): those match every
  worktree's runners and every chat's harness on the machine. `AGENTS.md`
  has the rule and a hook enforces it.

## iOS simulator

This section is the only place the simulator flow is described; other skills
link here.

1. Start the owner as its own background task, with the longest timeout:

   ```sh
   bun run ios-simulator > tmp/ios-simulator.log 2>&1
   ```

2. Wait for `Simulator ready` in its log, or for the task to exit; nothing
   else decides the outcome. Ready means it has created this worktree's
   device and booted it. If the task exits first, startup failed and the
   log's last lines say why.
3. Start `bun run dev:ios` in another background task. The runner builds,
   installs, and launches the app on that exact device.

### The ready block and the Xcode window

The owner also opens the worktree's project in Xcode and shows the device in
Simulator or DeviceHub, but the simulator never waits for either. Lines that
start `Xcode project window skipped` or
`The simulator is running but its window was not shown` are notes, not
failures, so do not search the log for "error" or "failed".

The ready block ends with an `Xcode:` line. Read it before using the Xcode
MCP:

| `Xcode:` line                                    | Meaning                                                                                                                                                                                                                                                                            |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `project window open`                            | The owner opened the project window and will close it when it stops.                                                                                                                                                                                                               |
| `project window was already open and stays open` | It reused a window that was already there and will leave it open.                                                                                                                                                                                                                  |
| `project window still opening; …`                | Xcode has not answered yet, which can last as long as it is busy. If you need the Xcode MCP, wait for a later `Opened an owned Xcode project window.`, `Reusing an existing Xcode project window; it will stay open.`, or `Xcode project window skipped` line; otherwise carry on. |
| `no project window; open it with xed …`          | Carry on with the dev runner, `simctl`, and `axe`. Only if you need the Xcode MCP, run `xed apps/ios/Codevisor.xcodeproj`; a window you open this way stays open when the owner stops.                                                                                             |

A problem with the Xcode window is never a reason to create your own device:
the simulator is running and the dev runner can use it.

macOS Accessibility access for the app or terminal running the command is
needed only for the Xcode window. Without it the simulator still starts, and
the window is skipped with a note.

### Rules

- The device UDID is in `tmp/runtime/ios-simulator.json`
  (`jq -r .udid tmp/runtime/ios-simulator.json`).
- The default device is `iPhone 17 Pro` on the newest compatible installed
  runtime. Choose another with
  `bun run ios-simulator --device="iPhone 17" --runtime=27.0`. Device
  selection belongs to this command only. Select the printed device in
  DeviceHub if another one is showing.
- Leave the owner running across dev-runner restarts. Stopping the task, or
  the task reaching its background time limit, shuts down and deletes its
  device and closes the Xcode project window it opened; a window that was
  already open is left open. It never quits Xcode. It cleans up the same way
  if its launcher dies, and a later launch recovers a device orphaned by a
  crash. Device files live in CoreSimulator's default location so DeviceHub
  can find them.
- Stopping can take up to 30 seconds longer when Xcode is not answering. The
  owner then deletes the device anyway and may leave the window open, with a
  `The Xcode project window was left as it is` note.
- Never quit Simulator, DeviceHub, Xcode, or `simctl` by name or pattern, and
  never boot, delete, or reuse another worktree's device.
- Rebuild and reinstall through the dev runner, not Xcode's Run button or
  the Xcode MCP's build tools, so the worktree's configuration is kept.

## Build without launching

```sh
bun run build:macos
bun run build:ios
```

- These are compile checks. `build:macos` produces an unsigned
  `Codevisor.app`, not this worktree's dev app, so do not launch it; use
  `bun run dev` to run the app.
- Extra arguments go straight to `xcodebuild`, for example
  `bun run build:macos -jobs 4`.
- They write to the same `tmp/build/<platform>/DerivedData` as the dev
  runner. Xcode builds one thing per DerivedData folder at a time, so do not
  run one while the dev runner is building that platform.
- `build:ios` needs no simulator. Tests never need one either:
  `bun run check`, the pre-push hook, and CI run only host unit tests and do
  not build iOS. Build archives the iOS app on every push to main.
- `bun run build:pixelbook` builds the PixelBook app the same way, and
  `bun run xcode:list` lists the macOS project's schemes and targets.

## Shared artifacts and disk

Version-pinned inputs live once under `~/.codevisor-development/artifacts/`
and are shared by every worktree on the same pinned version; a lock file
serializes concurrent first-time provisioning:

- GhosttyKit (`ghostty/`) and the Chromium/CEF SDK with its wrapper library
  (`chromium/`), fetched by the macOS build and linked into the worktree.
- The bun install cache (`bun-cache/`), SwiftPM's unpacked binary artifacts
  such as Sentry (`swift-artifacts/`, swapped in right after package
  resolution by `packages/devtools/src/swift-artifacts.ts`), and the signed
  Debug Chromium framework (`chromium/signed-frameworks/`). These reach the
  worktree as APFS clones, which share disk blocks until written. Swift
  artifact and Chromium entries unused for 30 days are pruned; the bun cache,
  like bun's default global cache, is not.

- The Rust networking library (`net/turbo-cache/`): the xcframework and the
  Node addons that the `build:swift` and `build:node:<target>` turbo tasks
  in `packages/net` produce. The dev runners, tests, and release scripts run
  those tasks against this one cache, so a build is keyed by turbo's hash of
  the task's inputs (`packages/net/turbo.json`: the crates, `Cargo.lock`,
  `rust-toolchain.toml`, the pins in `scripts/net-build.lock.json`, and the
  build scripts). A worktree with the same inputs gets the build restored
  into its own `packages/net/native` (about 0.3 GB); a worktree that changes
  any input gets a different hash and compiles its own, leaving the other
  builds untouched. A lock per hash makes worktrees that need the same
  build wait for the first one instead of compiling it twice. Builds unused
  for 30 days are pruned.

Only a worktree that compiles the networking library has a
`packages/net/target` (about 6 GB of cargo output, kept so its next Rust
edit rebuilds incrementally); delete it when that worktree is done with
Rust. A fresh macOS dev run that reuses the shared build measured about
10 GB in the worktree by `du`, half of it in `tmp/build`. Measure a
worktree's real cost with private (unshared) bytes, not `du`, which counts
every clone in full. Both folders are ignored build output; deleting `tmp/`
also deletes the dev instance's data and sign-in.

The runners install dependencies themselves, and a new worktree's
post-checkout hook does too, so `bun install` is not a setup step. Only when
intentionally rebuilding GhosttyKit itself, run `bun run ghostty:build`.

## Website and mascot playground

- `bun run dev:web` runs the website alone. The native runners also start it
  on the banner's `www:` address.
- `bun run dev:mascot-playground` opens a browser playground
  (`apps/mascot-playground`) that renders `@codevisor/bot-mascot` straight
  from `packages/bot-mascot/src`, so package edits hot-reload with no build
  step. It has every outfit option, every animation with play, pause, scrub,
  speed and loop, live arm-rig controls with debug overlays (drag on the
  stage to move an arm's target), the sidebar figure and circle avatar at 1×,
  2× and 3× on light and dark, PNG and SVG export of the current frame, and
  the whole state in the URL, so a link opens the same outfit, animation and
  frame.

## Common mistakes

- Reading a long first build as a hang and killing it, or switching to
  `xcodebuild` or `cargo`. The networking build reports progress every 20
  seconds; a run waiting on another worktree's build says so.
- Starting the runner or simulator owner with the default background timeout,
  then finding the app, servers, or simulator gone half an hour later.
- Quitting the Mac app to "restart" it, which stops the servers too.
- Running `bun run dev:ios` for a macOS-only change, which needs the
  simulator for nothing, or `dev:linux` for a change that does not touch the
  Linux server, sandboxes, or containers, which pays for a 4 GB VM for
  nothing.
- Launching the `build:macos` product, or building in Xcode, instead of
  using the dev runner.

To drive the running apps and capture screenshots or recordings, use the
`driving-dev-apps` skill.
