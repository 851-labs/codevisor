---
name: release-codevisor
description: Cut and monitor a new Codevisor release from the successful release candidate at current main HEAD. Use when the user asks to publish, release, or cut a new Codevisor version.
---

# Release Codevisor

Codevisor stable releases are manually dispatched from `main`. The workflow
requires a successful same-SHA release candidate, rebuilds the signed stable
artifacts from that RC's unsigned inputs, rechecks that `main` has not advanced,
then creates the immutable version tag and GitHub release. Do not create or
push the version tag yourself.

Fetch current `main`, verify the working tree is not hiding local release work,
and identify the successful Release candidate run for `origin/main`:

```sh
git status --short
git fetch origin main --tags
main_sha="$(git rev-parse origin/main)"
gh run list --workflow release-candidate.yml --commit "$main_sha" --status success --limit 5
```

Confirm the requested numeric version, make sure its tag does not already point
elsewhere, then dispatch the stable release on `main`:

```sh
git ls-remote --tags origin refs/tags/v0.1.0 refs/tags/v0.1.0^{}
gh workflow run release.yml --ref main -f version=0.1.0
```

Monitor the resulting Release workflow through completion. Verify its GitHub
assets, signatures/staples, latest-release API result, Homebrew update, and (for
the first GitHub-aware release only) frozen R2 bridge. If it fails before
tagging, fix `main`, wait for the new HEAD's RC, and dispatch the version from
that RC's provenance. Never move or replace an existing release tag without
explicit user authorization.
