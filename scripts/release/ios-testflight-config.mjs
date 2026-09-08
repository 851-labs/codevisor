import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

export const IOS_BUNDLE_ID = "com.dylanplayer.codevisor.ios"

export function testFlightConfiguration(version, environment = process.env) {
  if (!/^\d+\.\d+\.\d+$/.test(version ?? ""))
    throw new Error("A numeric marketing version is required.")
  const required = (key) => {
    const value = environment[key]
    if (!value) throw new Error(`${key} is required for iOS TestFlight CI.`)
    return value
  }
  const buildNumber = required("CODEVISOR_BUILD_NUMBER")
  const sourceRevision = required("CODEVISOR_SOURCE_REVISION")
  const teamId = required("APPLE_TEAM_ID")
  const keyId = required("APP_STORE_CONNECT_API_KEY_ID")
  const issuerId = required("APP_STORE_CONNECT_ISSUER_ID")
  if (!/^[1-9]\d*$/.test(buildNumber))
    throw new Error("The iOS build number must be a positive integer.")
  if (!/^[0-9a-f]{40}$/.test(sourceRevision))
    throw new Error("The iOS source revision must be a full commit SHA.")
  if (!/^[A-Z0-9]{10}$/.test(teamId))
    throw new Error("APPLE_TEAM_ID must be a 10-character team ID.")
  if (!/^[A-Z0-9]+$/.test(keyId)) throw new Error("Invalid App Store Connect key ID.")
  const privateKey = Buffer.from(required("APP_STORE_CONNECT_API_KEY_BASE64"), "base64").toString(
    "utf8"
  )
  return {
    version,
    buildNumber,
    sourceRevision,
    teamId,
    keyId,
    issuerId,
    privateKey,
    bundleId: IOS_BUNDLE_ID
  }
}

export function exportOptions(teamId) {
  return {
    method: "app-store-connect",
    destination: "export",
    teamID: teamId,
    signingStyle: "automatic",
    testFlightInternalTestingOnly: true,
    manageAppVersionAndBuildNumber: false,
    uploadSymbols: true
  }
}

export async function withSigningKey(configuration, operation) {
  const parent = process.env.CODEVISOR_APPLE_KEY_DIRECTORY || tmpdir()
  await mkdir(parent, { recursive: true, mode: 0o700 })
  const directory = await mkdtemp(join(parent, "codevisor-testflight-"))
  try {
    const keyPath = join(directory, `AuthKey_${configuration.keyId}.p8`)
    await writeFile(keyPath, configuration.privateKey, { mode: 0o600 })
    return await operation(keyPath)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

export function authenticationArguments(configuration, keyPath) {
  return [
    "-allowProvisioningUpdates",
    "-authenticationKeyPath",
    keyPath,
    "-authenticationKeyID",
    configuration.keyId,
    "-authenticationKeyIssuerID",
    configuration.issuerId
  ]
}

export async function fileSHA256(path) {
  return createHash("sha256")
    .update(await readFile(path))
    .digest("hex")
}

export function verifyBuildRecord(record, configuration, ipaSHA256) {
  for (const key of ["version", "buildNumber", "sourceRevision", "teamId", "bundleId"]) {
    if (record[key] !== configuration[key])
      throw new Error(`iOS artifact ${key} does not match this Alpha run.`)
  }
  if (record.ipaSHA256 !== ipaSHA256 || record.internalOnly !== true) {
    throw new Error("iOS artifact checksum or internal-only declaration is invalid.")
  }
}

export function assertAlphaUpload(environment) {
  if (
    environment.GITHUB_ACTIONS !== "true" ||
    environment.GITHUB_REF !== "refs/heads/main" ||
    !["push", "workflow_dispatch"].includes(environment.GITHUB_EVENT_NAME) ||
    environment.CODEVISOR_SOURCE_REVISION !== environment.GITHUB_SHA
  ) {
    throw new Error("TestFlight uploads require a trusted Alpha CI run for the exact main commit.")
  }
}
