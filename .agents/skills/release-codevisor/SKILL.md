---
name: release-codevisor
description: Promote the successful Alpha artifact set at current Codevisor main HEAD to a Stable release, with a complete changelog and end-to-end publication verification. Use when the user asks to publish, release, or cut a new Codevisor version.
---

# Release Codevisor

Stable is a promotion, never a rebuild. The `Alpha` workflow creates the only
signed and notarized app/server artifact set for a commit. `Publish Alpha`
publishes those bytes to the Alpha Sparkle channel. `Release` attaches the same
bytes to the Stable tag, advances the Stable Sparkle and Linux manifests,
updates Homebrew, and publishes the Chrome extension.

Do not create, move, or push a version tag manually. The workflow owns the tag.

## Prepare

Require a clean release scope and current remote state:

```sh
git status --short
git fetch origin main --tags
main_sha="$(git rev-parse origin/main)"
gh run list --workflow release-candidate.yml --commit "$main_sha" --status success --limit 5
```

Inspect the successful run's `codevisor-release-provenance` artifact. It must
say `channel: alpha`, use `main_sha`, and contain the numeric version and build
number. Also require a published `vVERSION-alpha.BUILD` prerelease for that
provenance. If the Alpha publisher has not run, dispatch
`publish-release-candidate.yml` and monitor it first.

Generate the prospective Stable notes locally:

```sh
node scripts/release/generate-release-notes.mjs \
  --channel stable \
  --version VERSION \
  --commit "$main_sha" \
  --output /tmp/codevisor-release-notes.md
```

Read the notes. Every non-merge commit since the previous Stable tag must
appear exactly once. Fix the generator or commit subjects before releasing if
coverage is incomplete; never substitute GitHub's automatic notes.

## Promote

Confirm the numeric version and ensure its immutable tag is unused:

```sh
git ls-remote --tags origin refs/tags/vVERSION refs/tags/vVERSION^{}
gh workflow run release.yml --ref main -f version=VERSION
```

Monitor the resulting `Release` workflow through completion.

## Verify

Verify all of the following before reporting success:

- `vVERSION` points to the original Alpha source SHA.
- The Stable macOS ZIP SHA-256 values equal the corresponding Alpha ZIP
  SHA-256 values byte-for-byte.
- The GitHub release body equals the generated changelog and is non-empty.
- Both Sparkle appcasts contain the promoted build without an Alpha channel,
  and the enclosures have valid Ed25519 signatures.
- `https://updates.codevisor.dev/server/stable.json` reports `VERSION` and all
  four server targets.
- macOS artifacts are Developer ID signed, notarized, and stapled.
- Homebrew points to the same Stable artifacts and keeps `auto_updates true`.
- The Chrome Web Store job succeeded.
- The first Sparkle migration release is GitHub `latest`; later Stable
  releases do not move that bridge pointer.

If publication fails before tagging, fix `main`, wait for the new HEAD's Alpha,
and dispatch the next unused version. If it fails after tagging, repair the
same release idempotently without moving the tag or rebuilding artifacts.
