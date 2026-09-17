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

import { makeCredentialCoordinator } from "./credential-coordinator.js"

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
          return JSON.parse(await readFile(path(id), "utf8")) as {
            operationId: string
            sealed: string
          }
        } catch (cause) {
          if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
          throw cause
        }
      },
      write: async (id, value) => {
        await atomicWriteJson(path(id), value)
        // The receipt is the only recovery path after a rotating provider
        // grant is consumed. Flush both file contents and the rename.
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
