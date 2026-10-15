import { execFile } from "node:child_process"
import { readFile, rm, open } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import {
  atomicWriteJson,
  makeSharedCredentialVault,
  readNativeOAuth,
  refreshSharedOAuth
} from "@codevisor/harness-manager"
import type { CredentialCoordinator, SharedOAuthHarness } from "@codevisor/harness-manager"
import { Schema } from "effect"

import { errorCode } from "../unknown-values.js"
import { makeCredentialCoordinator } from "./credential-coordinator.js"

const Receipt = Schema.Struct({ operationId: Schema.String, sealed: Schema.String })

export const sharedAccountVault = (dataDir: string, provided?: CredentialCoordinator) => {
  const coordinator = makeCredentialCoordinator({ dataDir })
  const path = (id: string) => join(dataDir, "shared-credentials", `${id}.receipt.json`)
  return makeSharedCredentialVault({
    coordinate: provided ?? coordinator,
    ...(provided ? {} : { readCached: coordinator.cached }),
    rotate: refreshSharedOAuth,
    receipt: {
      read: async (id) => {
        try {
          return Schema.decodeUnknownSync(Receipt)(JSON.parse(await readFile(path(id), "utf8")))
        } catch (cause) {
          if (errorCode(cause) === "ENOENT") return undefined
          throw cause
        }
      },
      write: async (id, value) => {
        await atomicWriteJson(path(id), value)
        for (const location of [path(id), join(dataDir, "shared-credentials")]) {
          const handle = await open(location, "r")
          try {
            await handle.sync()
          } finally {
            await handle.close()
          }
        }
      },
      remove: (id) => rm(path(id), { force: true })
    }
  })
}

const exec = promisify(execFile)
export const discoverNativeAccount = (
  harnessId: SharedOAuthHarness,
  directory: string,
  isDefault: boolean,
  managed: boolean,
  env: NodeJS.ProcessEnv
) =>
  readNativeOAuth({
    harnessId,
    directory,
    isDefault,
    ownership: managed ? "managed" : "external",
    env,
    exec: (command, args, options) => exec(command, [...args], { ...options, encoding: "utf8" })
  })
