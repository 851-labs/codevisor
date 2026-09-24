import assert from "node:assert/strict"
import test from "node:test"

import {
  BUILD_WORKFLOW,
  PROVENANCE_ASSET,
  TESTFLIGHT_ASSET,
  alphaBuildNumber,
  alphaTag,
  isPublishedRelease,
  newestAlphaTag,
  parseRemoteTags,
  pendingPublication,
  releaseAssetNames,
  verifyAlphaProvenance
} from "./alpha-release.mjs"

const repository = "example/codevisor"
const run = {
  id: 1000,
  repository: { full_name: repository },
  head_repository: { full_name: repository },
  path: BUILD_WORKFLOW,
  head_branch: "main",
  event: "push",
  status: "completed",
  conclusion: "success",
  run_number: 42,
  head_sha: "a".repeat(40)
}
const provenance = {
  channel: "alpha",
  version: "1.2.3",
  build_number: "1042",
  run_id: "1000",
  source_sha: run.head_sha,
  ghostty_stamp: `${"c".repeat(40)}-${"d".repeat(16)}`
}
const identity = verifyAlphaProvenance(run, provenance, repository)

test("a successful Build run on main yields the identity every release step trusts", () => {
  assert.deepEqual(identity, {
    version: "1.2.3",
    build: "1042",
    source_sha: run.head_sha,
    run_id: "1000",
    ghostty_stamp: provenance.ghostty_stamp,
    tag: "v1.2.3-alpha.1042"
  })
  assert.doesNotThrow(() =>
    verifyAlphaProvenance({ ...run, event: "workflow_dispatch" }, provenance, repository)
  )
})

test("runs from other workflows, branches, forks, or unfinished builds are rejected", () => {
  for (const override of [
    { repository: { full_name: "another/codevisor" } },
    { head_repository: { full_name: "fork/codevisor" } },
    { path: ".github/workflows/release-candidate.yml" },
    { head_branch: "feature" },
    { event: "pull_request" },
    { status: "in_progress" },
    { conclusion: "failure" }
  ])
    assert.throws(
      () => verifyAlphaProvenance({ ...run, ...override }, provenance, repository),
      /not a successful Build run/
    )
})

test("provenance that does not describe its own run is rejected", () => {
  for (const override of [
    { channel: "stable" },
    { version: "1.2.3-alpha" },
    { build_number: "42" },
    { build_number: "1043" },
    { build_number: "0" },
    { run_id: "1001" },
    { source_sha: "b".repeat(40) },
    { source_sha: "invalid" },
    { ghostty_stamp: "invalid" }
  ])
    assert.throws(
      () => verifyAlphaProvenance(run, { ...provenance, ...override }, repository),
      /provenance/
    )
})

test("only a public prerelease with every artifact and its provenance counts as published", () => {
  const assets = releaseAssetNames(identity).map((name) => ({ name }))
  assert.ok(assets.some(({ name }) => name === PROVENANCE_ASSET))
  assert.ok(assets.some(({ name }) => name === `GhosttyKit-${identity.ghostty_stamp}.tar.gz`))
  assert.ok(assets.some(({ name }) => name === "codevisor-server-darwin-x64.tar.gz.sha256"))
  const release = { isDraft: false, isPrerelease: true, assets }
  assert.equal(isPublishedRelease(release, identity), true)
  assert.equal(isPublishedRelease(undefined, identity), false)
  assert.equal(isPublishedRelease({ ...release, isDraft: true }, identity), false)
  assert.equal(isPublishedRelease({ ...release, isPrerelease: false }, identity), false)
  for (const missing of [PROVENANCE_ASSET, "Codevisor-arm64.dmg"])
    assert.equal(
      isPublishedRelease(
        { ...release, assets: assets.filter(({ name }) => name !== missing) },
        identity
      ),
      false
    )
})

test("build numbers continue above the retired workflow's last run", () => {
  assert.equal(alphaBuildNumber(1), 1001)
  assert.equal(alphaBuildNumber("42"), 1042)
  assert.ok(alphaBuildNumber(1) > 788)
})

test("a published Alpha still owes a TestFlight upload until its marker is attached", () => {
  const assets = releaseAssetNames(identity).map((name) => ({ name }))
  const release = { isDraft: false, isPrerelease: true, assets }
  assert.deepEqual(pendingPublication(undefined, identity), { macos: true, ios: true })
  assert.deepEqual(pendingPublication({ ...release, isDraft: true }, identity), {
    macos: true,
    ios: true
  })
  assert.deepEqual(pendingPublication(release, identity), { macos: false, ios: true })
  assert.deepEqual(
    pendingPublication({ ...release, assets: [...assets, { name: TESTFLIGHT_ASSET }] }, identity),
    { macos: false, ios: false }
  )
  // An incomplete release is republished, which drops its marker.
  assert.deepEqual(
    pendingPublication({ ...release, assets: [{ name: TESTFLIGHT_ASSET }] }, identity),
    { macos: true, ios: true }
  )
})

test("remote tags resolve annotated tags to their commit", () => {
  const tags = parseRemoteTags(
    [
      `${"1".repeat(40)}\trefs/tags/v1.2.3-alpha.1042`,
      `${"2".repeat(40)}\trefs/tags/v1.2.2`,
      `${"3".repeat(40)}\trefs/tags/v1.2.2^{}`,
      ""
    ].join("\n")
  )
  assert.equal(tags.get("v1.2.3-alpha.1042"), "1".repeat(40))
  assert.equal(tags.get("v1.2.2"), "3".repeat(40))
  assert.equal(tags.size, 2)
})

test("the newest build wins when a commit carries several Alpha tags", () => {
  assert.equal(alphaTag({ version: "1.2.3", build: "7" }), "v1.2.3-alpha.7")
  assert.equal(
    newestAlphaTag(["v1.2.3-alpha.788", "v1.2.3-alpha.1001", "v1.2.3", "v1.2.3-alpha.x", ""]),
    "v1.2.3-alpha.1001"
  )
  assert.equal(newestAlphaTag(["v1.2.3"]), undefined)
})
