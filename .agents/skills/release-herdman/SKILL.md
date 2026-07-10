---
name: release-herdman
description: Cut and monitor a new HerdMan release by creating and pushing its version tag. Use when the user asks to publish, release, or cut a new HerdMan version.
---

# Release HerdMan

HerdMan releases run from `.github/workflows/release.yml` when a `v*` tag is pushed.

Confirm the requested version and target commit, then make sure the tag does not already exist locally or remotely:

```sh
git status --short
git fetch origin --tags
git tag --list v0.1.0
git ls-remote --tags origin refs/tags/v0.1.0
```

Create and push the tag:

```sh
git tag v0.1.0 <commit>
git push origin v0.1.0
```

Monitor the resulting Release workflow through completion. If it fails, inspect the failing job in `.github/workflows/release.yml` and its logs. Never move or replace an existing release tag without explicit user authorization.
