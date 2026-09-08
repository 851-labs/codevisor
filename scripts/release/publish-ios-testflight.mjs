import { spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

import { appStoreClient, deliverInternalBuild, findApp } from "./app-store-connect.mjs"
import {
  assertAlphaUpload,
  fileSHA256,
  testFlightConfiguration,
  verifyBuildRecord,
  withSigningKey
} from "./ios-testflight-config.mjs"

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

const result = await deliverInternalBuild(client, { ...configuration, appId: app.id }, () =>
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
            stdio: "inherit"
          }
        )
        child.once("error", reject)
        child.once("exit", (code) =>
          code === 0
            ? resolveUpload()
            : reject(new Error(`TestFlight upload exited with code ${code}.`))
        )
      })
  )
)
console.log(
  `Internal TestFlight ${configuration.version} (${configuration.buildNumber}) is processed and assigned to ${result.group.attributes.name}.`
)
console.log(`https://appstoreconnect.apple.com/apps/${app.id}/testflight`)
