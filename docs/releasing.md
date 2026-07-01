# Releasing HerdMan

HerdMan releases are cut by `.github/workflows/release.yml`.

## What The Workflow Publishes

- `HerdMan-macOS.zip`: the macOS app cask artifact.
- `herdman-server-<target>.tar.gz`: standalone server and terminal proxy runtime archives for Homebrew.
- `Casks/herdman.rb` in `851-labs/homebrew-tap`.
- `Formula/herdman-server.rb` in `851-labs/homebrew-tap`.

The macOS app bundle includes the Node server runtime under
`HerdMan.app/Contents/Resources/server`. The app still depends on a Node runtime,
so the generated cask declares `depends_on formula: "node"`.

The app release script links `apps/macos/Frameworks/GhosttyKit.xcframework` when
it is present. If it is absent, the release still builds with the placeholder
terminal backend. Run `apps/macos/scripts/build-ghostty.sh` before the app
release step on a machine that can build GhosttyKit when the release should ship
the live libghostty terminal.

## Required Repository Secret

- `HOMEBREW_TAP_TOKEN`: a GitHub token with write access to
  `851-labs/homebrew-tap`.

## Optional macOS Signing And Notarization Secrets

When the Apple signing secrets are present, the app is signed and notarized before
the release zip is uploaded. Without them, the workflow ad-hoc signs the app so
CI can still produce a testable archive.

- `APPLE_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`.
- `APPLE_CODESIGN_IDENTITY`: signing identity name, for example
  `Developer ID Application: 851 Labs, LLC (TEAMID)`.
- `APPLE_ID`: Apple ID for `notarytool`.
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for `notarytool`.
- `APPLE_TEAM_ID`: Apple developer team id.

## Cutting A Release

Tag a release and push it:

```sh
git tag v0.1.0
git push origin v0.1.0
```

You can also run the workflow manually and provide a version. Manual releases
create or update the matching `v<version>` GitHub release for the current commit.

The macOS job must run on an image with an Xcode SDK that can build the current
project deployment target. Override the runner with the `macos_runner` workflow
input or the `HERDMAN_MACOS_RUNNER` repository variable when needed.
