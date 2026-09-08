import assert from "node:assert/strict"
import { access, readFile, stat } from "node:fs/promises"
import test from "node:test"

import {
  assertAlphaUpload,
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

test("export options require local output restricted to internal TestFlight", () => {
  const options = exportOptions("TEAM123456")
  assert.equal(options.destination, "export")
  assert.equal(options.testFlightInternalTestingOnly, true)
  assert.equal(options.manageAppVersionAndBuildNumber, false)
})

test("publishing rejects a substituted artifact or a different Alpha source", () => {
  const configuration = testFlightConfiguration("1.2.3", environment)
  const { privateKey: _privateKey, keyId: _keyId, issuerId: _issuerId, ...identity } = configuration
  const record = { ...identity, ipaSHA256: "expected", internalOnly: true }
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
  assert.throws(
    () => verifyBuildRecord({ ...record, internalOnly: false }, configuration, "expected"),
    /internal-only/
  )
})

test("upload guard permits exact main CI runs and rejects local, PR, and mismatched source runs", () => {
  const trusted = {
    GITHUB_ACTIONS: "true",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "push",
    GITHUB_SHA: environment.CODEVISOR_SOURCE_REVISION,
    CODEVISOR_SOURCE_REVISION: environment.CODEVISOR_SOURCE_REVISION
  }
  assert.doesNotThrow(() => assertAlphaUpload(trusted))
  for (const override of [
    { GITHUB_ACTIONS: "false" },
    { GITHUB_REF: "refs/heads/feature" },
    { GITHUB_EVENT_NAME: "pull_request" },
    { CODEVISOR_SOURCE_REVISION: "b".repeat(40) }
  ])
    assert.throws(() => assertAlphaUpload({ ...trusted, ...override }), /trusted Alpha/)
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
