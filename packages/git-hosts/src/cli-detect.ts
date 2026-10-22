import { accessSync, constants } from "node:fs"
import { join } from "node:path"

import { runCli } from "./cli-process.js"
import type { GitHostCli } from "./git-host.js"

const versionTimeoutMs = 10_000
const versionPattern = /(\d+\.\d+\.\d+)/

export const locateCli = (command: string, env: NodeJS.ProcessEnv): string | undefined =>
  pathDirectories(env)
    .map((directory) => join(directory, command))
    .find(isExecutable)

export const detectCli = async (
  command: string,
  env: NodeJS.ProcessEnv
): Promise<GitHostCli | undefined> => {
  const path = locateCli(command, env)
  if (path === undefined) return undefined

  return { path, version: await cliVersion(path, env) }
}

const pathDirectories = (env: NodeJS.ProcessEnv): ReadonlyArray<string> =>
  (env.PATH ?? "").split(":").filter((directory) => directory.length > 0)

const isExecutable = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

const cliVersion = async (path: string, env: NodeJS.ProcessEnv): Promise<string | undefined> => {
  const result = await runCli(path, ["--version"], env, { timeoutMs: versionTimeoutMs })
  return versionPattern.exec(result.stdout)?.[1]
}
