# Marketing screenshots

Capture the native apps with the same offline demo content for the website, App Store, and other marketing materials:

Start the worktree's simulator in a separate terminal and leave it running:

```sh
bun run ios-simulator --device="iPhone 13 Pro Max"
```

After it prints `Simulator ready`, run the capture commands:

```sh
bun run screenshots:ios
bun run screenshots:macos
```

Each command captures **projects, conversation, new chat, and browser preview in light and dark mode**: eight PNGs per platform. The shared Daylight project includes a focus-timer conversation, workspaces on Studio Mac and Linux Server, a Claude model selection, and a bundled browser preview. macOS keeps its native sidebar visible; its projects scene shows the default new-chat page, and its new-chat scene selects Daylight.

## Requirements

Run on a Mac with Xcode selected. iOS also needs a compatible Simulator runtime. macOS captures require an active graphical login and a display large enough for a 1280 × 820 point window. Allow Screen Recording for the terminal running the command. Xcode may request permission to run UI automation the first time.

The scripts use the repository's dependency bootstrap and Xcode build wrapper. Initial runs download native dependencies; later runs reuse the isolated build caches. No development server, account, API key, or AI session is needed. The macOS demo browser uses Chromium's mock Keychain so rebuilt screenshot apps do not request access to stored credentials.

Run one capture command at a time per platform in each worktree. The scripts use separate bundle identifiers and build directories from the development runner. iOS uses the worktree-owned simulator, fixes the status bar at 9:41 with a full battery, then clears the override and restores its appearance. Stop the simulator owner when finished to delete that device. macOS applies appearance to its own window. Neither command changes the host's system appearance.

## Output

Each run creates `tmp/screenshots/<platform>/capture-*` with:

- `iphone/light/`, `iphone/dark/`, or `macos/light/`, `macos/dark/`: original PNGs, named by scene, device, and appearance.
- `screenshots.zip`: PNGs, gallery, and manifest, ready to share.
- `index.html`: a gallery linking to the full-resolution images.
- `manifest.json`: scene, appearance, dimensions, runtime/OS version, bundle identity, source commit, and whether the checkout contains local changes.
- Build/test logs, XCTest results, and exported attachments for diagnosing failures. These are excluded from the zip.

The iPhone 13 Pro Max PNGs are **1284 × 2778**. macOS captures the **window including its title bar**, without the desktop: **2560 × 1640** on a Retina display, or **1280 × 820** at 1×. Images retain their native resolution; the scripts validate dimensions and reject missing or duplicate scene attachments.

Open the gallery before using the images in marketing materials. Both commands capture the current checkout, including local changes. A failed capture exits unsuccessfully and preserves diagnostics; the final manifest, gallery, and zip are written only after all requested scenes pass.

## Options

Both commands default to both appearances:

```sh
bun run screenshots:macos --appearance dark
bun run screenshots:ios --appearance light
bun run screenshots:macos --output tmp/my-screenshots
bun run screenshots:ios --runtime 'iOS 27.0'
```

`--appearance` accepts `all`, `light`, or `dark`. iOS additionally accepts `--device iphone` or `--device all`; both capture iPhone while iPad support is disabled. Its optional `--runtime` checks that the running simulator uses that runtime; select the runtime when starting `ios-simulator`.

## Shared implementation

- `apps/shared/Screenshots/`: demo conversation, sidebar records, model capabilities, environment/controller factories, appearance selection, and offline HTML. Both Xcode apps compile these same files only in Debug builds.
- `apps/shared/ScreenshotTests/`: shared scene order, content readiness checks, locale, and named XCTest attachments. iOS captures the screen; macOS requests a native capture by window ID from the CLI, excluding overlapping apps and window shadows. Ordinary test runs skip capture unless explicitly enabled by the scripts.
- Each app's `PreviewContent/`: a small adapter mounting its production native views with the shared inputs. The macOS entry point branches before live storage and server startup.
- `scripts/screenshots-lib.ts` and `scripts/screenshots-capture.ts`: shared options, appearances, isolated builds, attachment export, image validation, manifests, galleries, and zips.
- `scripts/screenshots-ios.ts` and `scripts/screenshots-macos.ts`: platform setup and capture loops.

Run the script checks with `node --test scripts/screenshots*.test.mjs`. Verify rendering by running both capture commands and reviewing the resulting images.
