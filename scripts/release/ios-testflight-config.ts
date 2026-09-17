import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

export const IOS_BUNDLE_ID = "com.dylanplayer.codevisor.ios"

export interface TestFlightConfiguration {
  version: string
  buildNumber: string
  sourceRevision: string
  teamId: string
  keyId: string
  issuerId: string
  privateKey: string
  bundleId: string
}

export interface ExportOptions {
  method: string
  destination: string
  teamID: string
  signingStyle: string
  testFlightInternalTestingOnly: boolean
  manageAppVersionAndBuildNumber: boolean
  uploadSymbols: boolean
}

// The build manifest the Alpha job writes beside the exported .ipa.
export interface TestFlightBuildRecord {
  appId?: string
  bundleId?: string
  teamId?: string
  version?: string
  buildNumber?: string
  sourceRevision?: string
  internalOnly?: boolean
  ipaSHA256?: string
}

// The subset of GitHub's workflow-run payload this provenance check reads.
export interface AlphaWorkflowRun {
  id: number | string
  repository?: { full_name?: string }
  head_repository?: { full_name?: string }
  path?: string
  head_branch?: string
  event: string
  status?: string
  conclusion?: string
  head_sha?: string
  run_number?: number | string
}

export interface AlphaProvenance {
  channel?: string
  version?: string
  build_number?: number | string
  source_sha?: string
}

export interface AlphaIdentity {
  version: string
  build: string
  source_sha: string
}

// Apple's and GitHub's optional values are compared against literal lists, so
// those lists are widened before an absent value is looked up in them.
type OptionalValues = readonly (string | undefined)[]

export function testFlightConfiguration(
  version: string | undefined,
  environment: NodeJS.ProcessEnv = process.env
): TestFlightConfiguration {
  if (version === undefined || !/^\d+\.\d+\.\d+$/.test(version))
    throw new Error("A numeric marketing version is required.")
  const required = (key: string) => {
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

export function exportOptions(teamId: string): ExportOptions {
  return {
    method: "app-store-connect",
    destination: "export",
    teamID: teamId,
    signingStyle: "automatic",
    // Alpha distribution stays internal; the same build can later be promoted.
    testFlightInternalTestingOnly: false,
    manageAppVersionAndBuildNumber: false,
    uploadSymbols: true
  }
}

export async function withSigningKey<Result>(
  configuration: TestFlightConfiguration,
  operation: (keyPath: string) => Promise<Result>
): Promise<Result> {
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

export function authenticationArguments(
  configuration: TestFlightConfiguration,
  keyPath: string
): string[] {
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

export async function fileSHA256(path: string): Promise<string> {
  return createHash("sha256")
    .update(await readFile(path))
    .digest("hex")
}

export function verifyBuildRecord(
  record: TestFlightBuildRecord,
  configuration: TestFlightConfiguration,
  ipaSHA256: string
): void {
  for (const key of ["version", "buildNumber", "sourceRevision", "teamId", "bundleId"] as const) {
    if (record[key] !== configuration[key])
      throw new Error(`iOS artifact ${key} does not match this Alpha run.`)
  }
  if (record.ipaSHA256 !== ipaSHA256 || record.internalOnly !== false) {
    throw new Error("iOS artifact checksum or App Store eligibility declaration is invalid.")
  }
}

export function assertAlphaUpload(environment: NodeJS.ProcessEnv): void {
  if (
    environment.GITHUB_ACTIONS !== "true" ||
    environment.GITHUB_REF !== "refs/heads/main" ||
    !(["push", "workflow_dispatch"] as OptionalValues).includes(environment.GITHUB_EVENT_NAME) ||
    environment.CODEVISOR_SOURCE_REVISION !== environment.GITHUB_SHA
  ) {
    throw new Error("TestFlight uploads require a trusted Alpha CI run for the exact main commit.")
  }
}

export function assertManualPromotion(environment: NodeJS.ProcessEnv): void {
  if (
    environment.GITHUB_ACTIONS !== "true" ||
    environment.GITHUB_WORKFLOW !== "Publish Beta" ||
    environment.GITHUB_REF !== "refs/heads/main" ||
    environment.GITHUB_EVENT_NAME !== "workflow_dispatch"
  ) {
    throw new Error(
      "Public TestFlight promotion requires the manual Publish Beta workflow on main."
    )
  }
}

export function verifyAlphaProvenance(
  run: AlphaWorkflowRun,
  provenance: AlphaProvenance,
  repository: string,
  runId: string
): AlphaIdentity {
  if (
    String(run.id) !== runId ||
    run.repository?.full_name !== repository ||
    run.head_repository?.full_name !== repository ||
    run.path !== ".github/workflows/release-candidate.yml" ||
    run.head_branch !== "main" ||
    !["push", "workflow_dispatch"].includes(run.event) ||
    run.status !== "completed" ||
    run.conclusion !== "success"
  )
    throw new Error("Select a successful Alpha workflow run from this repository's main branch.")
  if (
    provenance.channel !== "alpha" ||
    provenance.version === undefined ||
    !/^\d+\.\d+\.\d+$/.test(provenance.version) ||
    !/^[1-9]\d*$/.test(String(provenance.build_number)) ||
    String(provenance.build_number) !== String(run.run_number) ||
    provenance.source_sha === undefined ||
    !/^[0-9a-f]{40}$/.test(provenance.source_sha) ||
    provenance.source_sha !== run.head_sha
  )
    throw new Error("The Alpha provenance does not match the selected workflow run.")
  return {
    version: provenance.version,
    build: String(provenance.build_number),
    source_sha: provenance.source_sha
  }
}
