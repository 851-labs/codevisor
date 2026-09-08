import { execFileSync } from "node:child_process"
import { mkdir, rm, writeFile } from "node:fs/promises"
import { resolve, join } from "node:path"
import { fileURLToPath } from "node:url"

import { runXcodebuild } from "../xcodebuild.mjs"
import { appStoreClient, findApp } from "./app-store-connect.mjs"
import { prepareEmbeddedCode, verifyDistributionSignatures } from "./ios-code-signing.mjs"
import {
  authenticationArguments,
  exportOptions,
  fileSHA256,
  testFlightConfiguration,
  withSigningKey
} from "./ios-testflight-config.mjs"

const repoRoot = fileURLToPath(new URL("../..", import.meta.url))
const configuration = testFlightConfiguration(process.argv[2])
const output = resolve(repoRoot, "tmp/build/ios/testflight")
const archive = join(output, "Codevisor.xcarchive")
const exported = join(output, "export")

// Fail on account/app access before spending time compiling. The API key is
// used explicitly for export; no signed-in Xcode session is needed in CI.
const app = await findApp(appStoreClient(configuration), configuration.bundleId)
await rm(output, { recursive: true, force: true })
await mkdir(output, { recursive: true })
// A Mac-only runner may have full Xcode without its optional iOS platform.
// Xcode reuses the installed platform on subsequent runs.
await runXcodebuild(repoRoot, "ios", ["-downloadPlatform", "iOS"])
await runXcodebuild(repoRoot, "ios", [
  "-project",
  "apps/ios/Codevisor.xcodeproj",
  "-scheme",
  "Codevisor",
  "-configuration",
  "Release",
  "-destination",
  "generic/platform=iOS",
  "-archivePath",
  archive,
  `DEVELOPMENT_TEAM=${configuration.teamId}`,
  `MARKETING_VERSION=${configuration.version}`,
  `CURRENT_PROJECT_VERSION=${configuration.buildNumber}`,
  // Cloud signing at export time avoids installing development identities or
  // creating a new development certificate on every ephemeral runner.
  "CODE_SIGNING_ALLOWED=NO",
  "-quiet",
  "archive"
])
await prepareEmbeddedCode(join(archive, "Products/Applications/Codevisor.app"))

const optionsPath = join(output, "ExportOptions.plist")
execFileSync("plutil", ["-convert", "xml1", "-o", optionsPath, "-"], {
  input: JSON.stringify(exportOptions(configuration.teamId))
})
await withSigningKey(configuration, async (keyPath) => {
  await runXcodebuild(repoRoot, "ios", [
    "-exportArchive",
    "-archivePath",
    archive,
    "-exportOptionsPlist",
    optionsPath,
    "-exportPath",
    exported,
    ...authenticationArguments(configuration, keyPath)
  ])
})

const ipa = join(exported, "Codevisor.ipa")
const verification = join(output, "verification")
execFileSync("ditto", ["-x", "-k", ipa, verification])
const bundle = join(verification, "Payload/Codevisor.app")
await verifyDistributionSignatures(bundle, configuration.teamId)
const plist = (path) =>
  JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", path], { encoding: "utf8" }))
const info = plist(join(bundle, "Info.plist"))
for (const [key, expected] of Object.entries({
  CFBundleIdentifier: configuration.bundleId,
  CFBundleShortVersionString: configuration.version,
  CFBundleVersion: configuration.buildNumber,
  CFBundleDisplayName: "Codevisor",
  ITSAppUsesNonExemptEncryption: false
})) {
  if (info[key] !== expected)
    throw new Error(`Exported iOS ${key} does not match the requested build.`)
}
if (!info.NSLocalNetworkUsageDescription || !info.NSCameraUsageDescription) {
  throw new Error("The exported app is missing its permission descriptions.")
}
const sourcePrivacy = plist(join(repoRoot, "apps/ios/Codevisor/PrivacyInfo.xcprivacy"))
const exportedPrivacy = plist(join(bundle, "PrivacyInfo.xcprivacy"))
if (JSON.stringify(sourcePrivacy) !== JSON.stringify(exportedPrivacy)) {
  throw new Error("The exported app privacy manifest differs from the source manifest.")
}
const summary = plist(join(exported, "DistributionSummary.plist"))["Codevisor.ipa"][0]
const entitlements = summary.entitlements
if (
  entitlements["get-task-allow"] !== false ||
  entitlements["beta-reports-active"] !== true ||
  entitlements["application-identifier"] !== `${configuration.teamId}.${configuration.bundleId}`
) {
  throw new Error(
    "The exported app does not have the expected App Store distribution entitlements."
  )
}
const actualOptions = plist(join(exported, "ExportOptions.plist"))
if (
  actualOptions.testFlightInternalTestingOnly !== true ||
  actualOptions.destination !== "export"
) {
  throw new Error("Expected a local, internal-only TestFlight export.")
}

await writeFile(
  join(exported, "testflight-build.json"),
  JSON.stringify(
    {
      appId: app.id,
      bundleId: configuration.bundleId,
      teamId: configuration.teamId,
      version: configuration.version,
      buildNumber: configuration.buildNumber,
      sourceRevision: configuration.sourceRevision,
      internalOnly: true,
      ipaSHA256: await fileSHA256(ipa)
    },
    null,
    2
  ) + "\n"
)
execFileSync("ditto", [
  "-c",
  "-k",
  "--keepParent",
  archive,
  join(exported, "Codevisor.xcarchive.zip")
])
await rm(verification, { recursive: true, force: true })
console.log(
  `Prepared internal TestFlight ${configuration.version} (${configuration.buildNumber}): ${ipa}`
)
