---
name: release-codevisor
description: Promote the successful Alpha artifact set at current Codevisor main HEAD to a Stable release, with a complete changelog and end-to-end publication verification. Use when the user asks to publish, release, or cut a new Codevisor version.
---

# Release Codevisor

Stable is a promotion, never a rebuild. Three workflows produce every release:

- `Build` (`build.yml`) runs on pushes to main. It runs the checks in `CI`
  (`ci.yml`) first, then builds and signs the app, server, and iOS artifacts
  only if they pass. While one Build runs, later pushes wait and only the
  newest one runs next, covering every commit since the last Build that
  passed. Build never contacts Apple's distribution services.
- `Release alpha` (`release-alpha.yml`) runs every 30 minutes or on dispatch
  and ships the newest successful build: it notarizes the app, publishes the
  Alpha Sparkle and server feeds, then creates the `vVERSION-alpha.BUILD`
  prerelease with every artifact plus `release-provenance.json`. That
  prerelease is the release record. Its TestFlight job then uploads iOS to the
  internal group and attaches `ios-testflight-build.json`; a missing marker is
  retried on the next run. Builds superseded between runs are never published
  and cannot be promoted.
- `Release stable` (`release-stable.yml`) takes a published Alpha tag, verifies
  it, and ships the same bytes as Stable: tag, Stable Sparkle and server feeds,
  Homebrew, and a versioned Chrome extension package. After that it calls
  `Release browser extension` with `only_if_changed`, which submits the
  extension to the Chrome Web Store only when
  `packages/automation/resources/browser-extension` changed since the newest
  `browser-extension-v<version>` tag, then tags the submitted version.

After publication verification passes, `Release stable` marks the release as
GitHub `latest`. Alpha releases remain prereleases and never advance `latest`.

Public iOS TestFlight publication uses the separate, manually triggered
`Release beta` workflow. Do not dispatch it as part of a normal
macOS/server release; submit an iOS beta only when requested.

Do not create, move, or push a version tag manually. The workflow owns the tag.

## Prepare

Require a clean release scope and find the Alpha to promote:

```sh
git status --short
git fetch origin main --tags
git tag --points-at origin/main --list 'v*-alpha.*'
```

If main HEAD has no published Alpha yet, dispatch `release-alpha.yml` (it
publishes the newest successful Build run) and monitor it, or promote an older
published Alpha instead: `gh release list --limit 10` lists them. Record the
Alpha's commit as `source_sha`:

```sh
source_sha="$(git rev-parse 'vVERSION-alpha.BUILD^{commit}')"
```

Generate the prospective Stable notes locally:

```sh
node scripts/release/generate-release-notes.mjs \
  --channel stable \
  --version VERSION \
  --commit "$source_sha" \
  --output /tmp/codevisor-release-notes.md
```

Read the notes. Every non-merge commit since the previous Stable tag must
appear exactly once. Fix the generator or commit subjects before releasing if
coverage is incomplete; never substitute GitHub's automatic notes.

## Promote

Confirm the numeric version and ensure its immutable tag is unused:

```sh
git ls-remote --tags origin refs/tags/vVERSION refs/tags/vVERSION^{}
gh workflow run release-stable.yml --ref main -f version=VERSION
```

Without `alpha_tag`, the workflow promotes the Alpha published for current main
HEAD. To promote an older published Alpha, pass its tag; the workflow tags that
Alpha's commit, not HEAD:

```sh
gh workflow run release-stable.yml --ref main -f version=VERSION -f alpha_tag=vVERSION-alpha.BUILD
```

Monitor the resulting `Release stable` workflow through completion.

## Verify

Verify all of the following before reporting success:

- `vVERSION` points to the original Alpha source SHA (the promoted Alpha's
  commit, which may be behind main HEAD when `alpha_tag` was given).
- The Stable macOS ZIP SHA-256 values equal the corresponding Alpha ZIP
  SHA-256 values byte-for-byte.
- The GitHub release body equals the generated changelog and is non-empty.
- The arm64 Sparkle appcast contains the promoted build without an Alpha
  channel, and its enclosure has a valid Ed25519 signature.
- `https://updates.codevisor.dev/server/stable.json` reports `VERSION` and all
  four server targets.
- macOS artifacts are Developer ID signed, notarized, and stapled.
- Homebrew points to the same Stable artifacts and keeps `auto_updates true`.
- The versioned Chrome extension ZIP and checksum are attached to the Stable
  release, and the `submit-browser-extension` job either logged why it skipped
  or pushed `browser-extension-v<VERSION>`. Dispatch `Publish Chrome Extension`
  by hand only to re-run a submission the user asks for; `dry_run` checks the
  package and Google sign-in without submitting.
- GitHub `latest` points to the promoted Stable release, and both architecture
  download URLs under `releases/latest/download` resolve to that release.

If publication fails before tagging, fix `main`, wait for the new HEAD's Alpha
to be published, and dispatch the next unused version. If it fails after tagging, repair the
same release idempotently without moving the tag or rebuilding artifacts.
