import { execFileSync } from "node:child_process"
import { appendFile, readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import { appStoreClient, findApp } from "./app-store-connect.mjs"
import {
  assertManualPromotion,
  fileSHA256,
  testFlightConfiguration,
  verifyBuildRecord
} from "./ios-testflight-config.mjs"
import { promoteTestFlightBuild, testFlightReleaseNotes } from "./testflight-release.mjs"

const [version, artifactDirectory, notesPath, mode] = process.argv.slice(2)
if (!version || !artifactDirectory || !notesPath || (mode && mode !== "--check"))
  throw new Error(
    "Usage: promote-ios-testflight.mjs VERSION ARTIFACT_DIRECTORY RELEASE_NOTES [--check]"
  )
const checkOnly = mode === "--check"
if (!checkOnly) assertManualPromotion(process.env)
const configuration = testFlightConfiguration(version)
const directory = resolve(artifactDirectory)
const record = JSON.parse(await readFile(join(directory, "testflight-build.json"), "utf8"))
verifyBuildRecord(record, configuration, await fileSHA256(join(directory, "Codevisor.ipa")))
const alphaTag = `v${version}-alpha.${configuration.buildNumber}`
{
  const tagSHA = execFileSync("git", ["rev-parse", `refs/tags/${alphaTag}^{commit}`], {
    encoding: "utf8"
  }).trim()
  if (tagSHA !== configuration.sourceRevision)
    throw new Error("The published Alpha tag does not match the selected iOS artifact.")
}
const client = appStoreClient(configuration)
const app = await findApp(client, configuration.bundleId)
if (record.appId !== app.id) throw new Error("The Alpha iOS artifact belongs to another app.")
const releaseURL = `https://github.com/${process.env.GITHUB_REPOSITORY ?? "851-labs/codevisor"}/releases/tag/${alphaTag}`
const notes = testFlightReleaseNotes(version, await readFile(notesPath, "utf8"), releaseURL)
const result = await promoteTestFlightBuild(
  client,
  { ...configuration, appId: app.id },
  {
    groupName: process.env.CODEVISOR_TESTFLIGHT_EXTERNAL_GROUP || "Beta",
    locale: app.attributes.primaryLocale || "en-US",
    notes,
    checkOnly
  }
)
const status = {
  checked: "Read-only preflight passed. No TestFlight settings changed.",
  testing: "Available to external testers.",
  notified: "Ready for external testing; tester notifications requested.",
  approved: "Beta review approved. Automatic tester distribution is enabled.",
  submitted: `Submitted for beta review (${result.reviewState}). Testers will be notified after approval.`
}[result.status]
const appURL = `https://appstoreconnect.apple.com/apps/${app.id}/testflight`
const summary = [
  `iOS TestFlight ${version} (${configuration.buildNumber})`,
  status,
  `Group: ${result.groupName}`,
  ...(result.renamedGroupFrom
    ? [`Renamed existing group: ${result.renamedGroupFrom} → ${result.groupName}`]
    : []),
  `Source: ${configuration.sourceRevision}`,
  appURL,
  ...(result.publicLink ? [`Public invitation: ${result.publicLink}`] : []),
  ""
].join("\n\n")
console.log(summary)
if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, summary)
