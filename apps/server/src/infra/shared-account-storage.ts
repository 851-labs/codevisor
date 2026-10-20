import { execFile } from "node:child_process"
import { readFile, rm, open } from "node:fs/promises"
import { join } from "node:path"

import {
  atomicWriteJson,
  forgetClaudeProfileLogin,
  makeSharedCredentialVault,
  readClaudeMachineLogin,
  readNativeOAuth,
  refreshSharedOAuth,
  signOutClaudeMachineLogin,
  withClaudeRefreshLock
} from "@codevisor/harness-manager"
import type {
  ClaudeMachineLoginOptions,
  CredentialCoordinator,
  SharedOAuthHarness
} from "@codevisor/harness-manager"
import { Schema } from "effect"

import { errorCode } from "../unknown-values.js"
import type { MachineClaudeLogin } from "./claude-login-takeover.js"
import { claudeMachineLocation } from "./claude-machine-location.js"
import { makeCredentialCoordinator } from "./credential-coordinator.js"

const Receipt = Schema.Struct({ operationId: Schema.String, sealed: Schema.String })

export const sharedAccountVault = (dataDir: string, provided?: CredentialCoordinator) => {
  const coordinator = makeCredentialCoordinator({ dataDir })
  const path = (id: string) => join(dataDir, "shared-credentials", `${id}.receipt.json`)
  return makeSharedCredentialVault({
    coordinate: provided ?? coordinator,
    ...(provided ? {} : { readCached: coordinator.cached }),
    rotate: refreshSharedOAuth,
    log: (line) => console.error(line),
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

const nativeExec: ClaudeMachineLoginOptions["exec"] = (command, args, { input, ...options }) =>
  new Promise((resolve, reject) => {
    const child = execFile(
      command,
      [...args],
      { ...options, encoding: "utf8" },
      (error, stdout, stderr) => {
        if (error) reject(error)
        else resolve({ stdout, stderr })
      }
    )
    child.stdin?.end(input)
  })

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
    exec: nativeExec
  })

export const forgetNativeProfileLogin = (directory: string, env: NodeJS.ProcessEnv) =>
  forgetClaudeProfileLogin({
    directory,
    env,
    platform: process.platform,
    exec: nativeExec
  })

export const nativeClaudeMachine =
  (dataDir: string) =>
  (env: NodeJS.ProcessEnv): MachineClaudeLogin => {
    const location = claudeMachineLocation(env, dataDir)
    const options = { location, env, exec: nativeExec, platform: process.platform }
    return {
      read: () => readClaudeMachineLogin(options),
      whileLocked: (body) => withClaudeRefreshLock(location.directory, body),
      signOut: () => signOutClaudeMachineLogin(options)
    }
  }
