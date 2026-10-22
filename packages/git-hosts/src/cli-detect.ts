import { accessSync, constants } from "node:fs"
import { join } from "node:path"

import { runCli } from "./cli-process.js"
import type { GitHostCli } from "./git-host.js"

const versionTimeoutMs = 10_000
const versionPattern = /(\d+\.\d+\.\d+)/

export const managedBin = (toolsDir: string): string => join(toolsDir, "bin")

export const locateCli = (
  command: string,
  env: NodeJS.ProcessEnv,
  toolsDir?: string
): string | undefined =>
  searchDirectories(env, toolsDir)
    .map((directory) => join(directory, command))
    .find(isExecutable)

export const detectCli = async (
  command: string,
  env: NodeJS.ProcessEnv,
  toolsDir?: string
): Promise<GitHostCli | undefined> => {
  const path = locateCli(command, env, toolsDir)
  if (path === undefined) return undefined

  return describeCli(path, env)
}

export const describeCli = async (path: string, env: NodeJS.ProcessEnv): Promise<GitHostCli> => ({
  path,
  version: await cliVersion(path, env)
})

const searchDirectories = (
  env: NodeJS.ProcessEnv,
  toolsDir: string | undefined
): ReadonlyArray<string> => {
  const onPath = (env.PATH ?? "").split(":").filter((directory) => directory.length > 0)
  if (toolsDir === undefined) return onPath

  return [...onPath, managedBin(toolsDir)]
}

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
