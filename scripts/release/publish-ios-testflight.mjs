import { spawn } from "node:child_process"
import { appendFile, readFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

import { appStoreClient, deliverInternalBuild, findApp } from "./app-store-connect.mjs"
import {
  assertAlphaUpload,
  fileSHA256,
  isUploadLimitError,
  testFlightConfiguration,
  verifyBuildRecord,
  withSigningKey
} from "./ios-testflight-config.mjs"

class UploadLimitReached extends Error {}

assertAlphaUpload(process.env)
const configuration = testFlightConfiguration(process.argv[2])
const directory = resolve(process.argv[3] ?? "tmp/build/ios/testflight/export")
const ipa = join(directory, "Codevisor.ipa")
const record = JSON.parse(await readFile(join(directory, "testflight-build.json"), "utf8"))
verifyBuildRecord(record, configuration, await fileSHA256(ipa))
const client = appStoreClient(configuration)
const app = await findApp(client, configuration.bundleId)
if (record.appId !== app.id)
  throw new Error("The prepared artifact belongs to a different App Store Connect app.")

const upload = () =>
  withSigningKey(
    configuration,
    (keyPath) =>
      new Promise((resolveUpload, reject) => {
        const child = spawn(
          "xcrun",
          [
            "altool",
            "--upload-app",
            "-f",
            ipa,
            "-t",
            "ios",
            "--apiKey",
            configuration.keyId,
            "--apiIssuer",
            configuration.issuerId
          ],
          {
            env: { ...process.env, API_PRIVATE_KEYS_DIR: dirname(keyPath) },
            stdio: ["ignore", "pipe", "pipe"]
          }
        )
        let output = ""
        for (const [stream, sink] of [
          [child.stdout, process.stdout],
          [child.stderr, process.stderr]
        ])
          stream.on("data", (chunk) => {
            output += chunk
            sink.write(chunk)
          })
        child.once("error", reject)
        child.once("close", (code) => {
          if (code === 0) resolveUpload()
          else if (isUploadLimitError(output)) reject(new UploadLimitReached())
          else reject(new Error(`TestFlight upload exited with code ${code}.`))
        })
      })
  )

let result
try {
  result = await deliverInternalBuild(client, { ...configuration, appId: app.id }, upload)
} catch (error) {
  if (!(error instanceof UploadLimitReached)) throw error
  // Apple's per-app daily upload limit is not a build failure. No marker is
  // attached, so the next Publish Alpha run retries after the limit resets.
  const message = `Skipped TestFlight upload of ${configuration.version} (${configuration.buildNumber}): Apple's daily upload limit is reached.`
  console.log(`::warning title=TestFlight upload skipped::${message}`)
  if (process.env.GITHUB_STEP_SUMMARY)
    await appendFile(process.env.GITHUB_STEP_SUMMARY, `${message}\n`)
  process.exit(0)
}
console.log(
  `Internal TestFlight ${configuration.version} (${configuration.buildNumber}) is processed and assigned to ${result.group.attributes.name}.`
)
console.log(`https://appstoreconnect.apple.com/apps/${app.id}/testflight`)
if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, "uploaded=true\n")
