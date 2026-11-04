import { accessSync, constants, existsSync } from "node:fs"
import { homedir } from "node:os"
import { delimiter, join } from "node:path"

import type { RunProcess } from "./shopify-process.js"
import { ShopifyToolError } from "./shopify-store.js"

export interface CliCommand {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

export interface CliInstallDeps {
  readonly env: Readonly<Record<string, string | undefined>>
  readonly toolsDir: string
  readonly nodePath: string
  readonly run: RunProcess
  readonly isExecutable?: (path: string) => boolean
  readonly exists?: (path: string) => boolean
}

export const pinnedCliVersion = "5.0.1"

export const defaultToolsDir = (env: Readonly<Record<string, string | undefined>>): string =>
  join(env.CODEVISOR_DATA_DIR ?? join(homedir(), ".codevisor", "data"), "tools", "shopify-cli")

export const makeCliLocator = (deps: CliInstallDeps): (() => Promise<CliCommand>) => {
  const isExecutable = deps.isExecutable ?? executable
  const exists = deps.exists ?? existsSync
  let installing: Promise<CliCommand> | undefined

  const located = (): CliCommand | undefined => {
    const onPath = findOnPath(deps.env, "shopify", isExecutable)
    if (onPath !== undefined) return { command: onPath, args: [] }
    const managed = managedEntry(deps.toolsDir)
    if (exists(managed)) return { command: deps.nodePath, args: [managed] }

    return undefined
  }

  const install = async (): Promise<CliCommand> => {
    const npm = findOnPath(deps.env, "npm", isExecutable)
    if (npm === undefined) throw new ShopifyToolError(needsNode)
    const result = await deps.run(npm, npmInstallArgs(deps.toolsDir), {
      timeoutMs: installTimeoutMs
    })
    if (result.code !== 0) throw new ShopifyToolError(installFailed(result.stderr))

    return { command: deps.nodePath, args: [managedEntry(deps.toolsDir)] }
  }

  return async () => {
    const found = located()
    if (found !== undefined) return found

    installing ??= install().finally(() => {
      installing = undefined
    })
    return installing
  }
}

const managedEntry = (toolsDir: string): string =>
  join(toolsDir, "node_modules", "@shopify", "cli", "bin", "run.js")

const npmInstallArgs = (toolsDir: string): ReadonlyArray<string> => [
  "install",
  "--prefix",
  toolsDir,
  "--no-audit",
  "--no-fund",
  "--loglevel=error",
  `@shopify/cli@${pinnedCliVersion}`
]

const findOnPath = (
  env: Readonly<Record<string, string | undefined>>,
  name: string,
  isExecutable: (path: string) => boolean
): string | undefined =>
  (env.PATH ?? "")
    .split(delimiter)
    .filter((directory) => directory !== "")
    .map((directory) => join(directory, name))
    .find(isExecutable)

const executable = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

const installTimeoutMs = 5 * 60_000

const needsNode =
  "Shopify needs the Shopify CLI, and installing it needs npm. Install Node.js from https://nodejs.org, then try again."

const installFailed = (stderr: string): string =>
  `Couldn't install the Shopify CLI: ${stderr.trim() || "npm failed"}`
