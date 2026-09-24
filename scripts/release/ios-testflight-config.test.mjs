import assert from "node:assert/strict"
import { access, readFile, stat } from "node:fs/promises"
import test from "node:test"

import {
  assertAlphaUpload,
  assertManualPromotion,
  isUploadLimitError,
  exportOptions,
  testFlightConfiguration,
  verifyBuildRecord,
  withSigningKey
} from "./ios-testflight-config.mjs"

const environment = {
  APPLE_TEAM_ID: "TEAM123456",
  APP_STORE_CONNECT_API_KEY_ID: "EXAMPLEKEY",
  APP_STORE_CONNECT_ISSUER_ID: "example-issuer",
  APP_STORE_CONNECT_API_KEY_BASE64: Buffer.from("test key").toString("base64"),
  CODEVISOR_BUILD_NUMBER: "42",
  CODEVISOR_SOURCE_REVISION: "a".repeat(40)
}

test("release configuration requires CI signing inputs and keeps the build identity explicit", () => {
  const configuration = testFlightConfiguration("1.2.3", environment)
  assert.equal(configuration.teamId, "TEAM123456")
  assert.equal(configuration.buildNumber, "42")
  assert.equal(configuration.privateKey, "test key")
  assert.throws(() => testFlightConfiguration("1.2.3", {}), /CODEVISOR_BUILD_NUMBER/)
  assert.throws(() => testFlightConfiguration("1.2.3-alpha", environment), /marketing version/)
  assert.throws(
    () =>
      testFlightConfiguration("1.2.3", {
        ...environment,
        CODEVISOR_BUILD_NUMBER: "1; echo unsafe"
      }),
    /positive integer/
  )
  assert.throws(
    () => testFlightConfiguration("1.2.3", { ...environment, APPLE_TEAM_ID: "" }),
    /APPLE_TEAM_ID/
  )
})

test("export options keep local output eligible for external TestFlight and the App Store", () => {
  const options = exportOptions("TEAM123456")
  assert.equal(options.method, "app-store-connect")
  assert.equal(options.destination, "export")
  assert.equal(options.testFlightInternalTestingOnly, false)
  assert.equal(options.manageAppVersionAndBuildNumber, false)
})

test("publishing rejects a substituted artifact or a different Alpha source", () => {
  const configuration = testFlightConfiguration("1.2.3", environment)
  const { privateKey: _privateKey, keyId: _keyId, issuerId: _issuerId, ...identity } = configuration
  const record = { ...identity, ipaSHA256: "expected", internalOnly: false }
  assert.doesNotThrow(() => verifyBuildRecord(record, configuration, "expected"))
  assert.throws(() => verifyBuildRecord(record, configuration, "changed"), /checksum/)
  assert.throws(
    () =>
      verifyBuildRecord({ ...record, sourceRevision: "b".repeat(40) }, configuration, "expected"),
    /sourceRevision/
  )
  assert.throws(
    () => verifyBuildRecord({ ...record, teamId: "OTHERTEAM1" }, configuration, "expected"),
    /teamId/
  )
  for (const internalOnly of [true, undefined])
    assert.throws(
      () => verifyBuildRecord({ ...record, internalOnly }, configuration, "expected"),
      /App Store eligibility/
    )
})

test("uploads come only from Publish Alpha on main, scheduled or manual, for an earlier build", () => {
  const trusted = {
    GITHUB_ACTIONS: "true",
    GITHUB_WORKFLOW: "Publish Alpha",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "schedule",
    GITHUB_SHA: "b".repeat(40),
    CODEVISOR_SOURCE_REVISION: environment.CODEVISOR_SOURCE_REVISION
  }
  assert.doesNotThrow(() => assertAlphaUpload(trusted))
  assert.doesNotThrow(() =>
    assertAlphaUpload({ ...trusted, GITHUB_EVENT_NAME: "workflow_dispatch" })
  )
  for (const override of [
    { GITHUB_ACTIONS: "false" },
    { GITHUB_WORKFLOW: "Build" },
    { GITHUB_REF: "refs/heads/feature" },
    { GITHUB_EVENT_NAME: "push" },
    { GITHUB_EVENT_NAME: "pull_request" }
  ])
    assert.throws(() => assertAlphaUpload({ ...trusted, ...override }), /Publish Alpha workflow/)
})

test("temporary API key is private and removed even when signing fails", async () => {
  let keyPath
  await assert.rejects(
    withSigningKey({ privateKey: "test key", keyId: "EXAMPLEKEY" }, async (path) => {
      keyPath = path
      assert.equal(await readFile(path, "utf8"), "test key")
      assert.equal((await stat(path)).mode & 0o777, 0o600)
      throw new Error("signing failed")
    }),
    /signing failed/
  )
  await assert.rejects(access(keyPath), { code: "ENOENT" })
})

test("public TestFlight requires its own manual workflow and permits an older selected Alpha", () => {
  const trusted = {
    GITHUB_ACTIONS: "true",
    GITHUB_WORKFLOW: "Publish Beta",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_SHA: "b".repeat(40),
    CODEVISOR_SOURCE_REVISION: environment.CODEVISOR_SOURCE_REVISION
  }
  assert.doesNotThrow(() => assertManualPromotion(trusted))
  for (const override of [
    { GITHUB_ACTIONS: "false" },
    { GITHUB_WORKFLOW: "Build" },
    { GITHUB_WORKFLOW: "Publish Stable" },
    { GITHUB_WORKFLOW: "Publish iOS TestFlight" },
    { GITHUB_EVENT_NAME: "push" },
    { GITHUB_EVENT_NAME: "workflow_run" },
    { GITHUB_REF: "refs/heads/feature" }
  ])
    assert.throws(() => assertManualPromotion({ ...trusted, ...override }), /manual Publish Beta/)
})

test("Apple's daily upload limit is recognized, other upload failures are not", () => {
  assert.equal(
    isUploadLimitError(
      "ERROR: [altool.7A9A] Upload limit reached. The upload limit for your application has been reached. Please wait 1 day and try again. (90382)"
    ),
    true
  )
  assert.equal(isUploadLimitError("ERROR: Invalid Signature. (90035)"), false)
  assert.equal(isUploadLimitError("Network connection was lost"), false)
})
