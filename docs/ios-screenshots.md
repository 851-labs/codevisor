# iOS screenshots

Run from any Codevisor worktree on a Mac with Xcode selected and a compatible iOS Simulator runtime installed:

```sh
bun run screenshots:ios
```

This builds the actual Debug app and captures four native screens on an iPhone 13 Pro Max, in this order: projects, conversation, new chat sheet, and browser preview. Native iPad support is currently disabled, so the script captures only iPhone screenshots. The portfolio workspace includes a Claude chat in progress. The browser contains a bundled example project. All content is fixed, offline demo data; no account, API key, AI session, or development server is needed.

Each run writes a new `tmp/screenshots/ios/capture-*` directory containing:

- `iphone/`: full-resolution portrait PNGs with device suffixes, such as `01-projects-iphone.png`.
- `index.html`: a gallery linking to the original images.
- `manifest.json`: device sizes, simulator runtime, source commit, and whether the checkout had uncommitted changes.
- Build/test logs, XCTest result bundles, and exported attachments for diagnosing failures.

The iPhone PNGs are **1284 × 2778**, accepted in App Store Connect’s **6.5-inch iPhone** slot. The script validates every exported image against these exact dimensions and fails on a mismatch. See [Apple’s screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

Open the gallery to review the images before uploading them to App Store Connect. The command does not upload or publish anything. It captures the current checkout, including uncommitted changes.

To select a specific installed runtime or output directory:

```sh
bun run screenshots:ios --runtime 'iOS 27.0'
bun run screenshots:ios --output tmp/my-screenshots
```

`--device iphone` and `--device all` both capture only iPhone. `--device ipad` is rejected while native iPad support is disabled.

The script creates and removes its own simulators, sets a light appearance and a fixed September 14, 2026, 9:41 status bar, and uses a separate bundle identifier and build directory. Its display name is Codevisor, matching the release app. Existing simulator apps and worktree development state are left alone. Run one capture command at a time per worktree; different worktrees have separate build directories and bundle identifiers.

The capture entry point is compiled only in Debug builds and branches before normal app startup. `AppStoreScreenshotData.swift` holds the sample conversation and sidebar records; `AppStoreScreenshotPage.swift` holds the example web page. `AppStoreScreenshotRoot.swift` mounts the production views with these inputs. `AppStoreScreenshotTests.swift` waits for each scene's content and saves named XCTest attachments. Ordinary test runs skip this capture test unless the script enables it.

If capture fails, the command exits unsuccessfully, retains the logs and result bundle, and removes its simulator. It creates the final gallery only after every requested screenshot has been exported successfully.
