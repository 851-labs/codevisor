import type { PluginManifest } from "@codevisor/api"
import { compareSemanticVersions } from "@codevisor/api"
import { constants } from "node:fs"
import { access } from "node:fs/promises"
import { delimiter, extname, join } from "node:path"
import { PluginsError } from "./plugins-error.js"

export type FindExecutable = (name: string, env: NodeJS.ProcessEnv) => Promise<string | undefined>

/// Resolves a direct-execution command from PATH. This deliberately ignores
/// shell aliases and functions because protocol v2 commands do too.
export const findExecutableOnPath: FindExecutable = async (name, env) => {
  const path = env["PATH"] ?? process.env["PATH"] ?? ""
  /* v8 ignore start -- Windows PATHEXT resolution cannot execute in the macOS/Linux test jobs. */
  const extensions =
    process.platform === "win32" ? (env["PATHEXT"] ?? ".EXE;.CMD;.BAT;.COM").split(";") : [""]
  const names =
    process.platform === "win32" && extname(name) === ""
      ? extensions.map((extension) => `${name}${extension.toLowerCase()}`)
      : [name]
  /* v8 ignore stop */
  for (const directory of path.split(delimiter).filter((entry) => entry.length > 0)) {
    for (const candidateName of names) {
      const candidate = join(directory, candidateName)
      try {
        await access(candidate, constants.X_OK)
        return candidate
      } catch {
        // Continue through PATH.
      }
    }
  }
  return undefined
}

export const assertGitAvailable = async (
  env: NodeJS.ProcessEnv,
  findExecutable: FindExecutable = findExecutableOnPath
): Promise<void> => {
  if ((await findExecutable("git", env)) !== undefined) return
  throw new PluginsError(
    "unavailable",
    "Remote plugin installation requires Git. Install Git, then try again. On macOS, run `xcode-select --install`."
  )
}

export const assertPluginRequirements = async (options: {
  readonly manifest: PluginManifest
  readonly platform: string
  readonly codevisorVersion?: string
  readonly env: NodeJS.ProcessEnv
  readonly findExecutable?: FindExecutable
}): Promise<void> => {
  const { manifest } = options
  if (manifest.platforms !== undefined && !manifest.platforms.includes(options.platform)) {
    throw new PluginsError(
      "invalid",
      `Plugin ${manifest.id} does not support ${options.platform}; supported platforms: ${manifest.platforms.join(", ")}`
    )
  }
  if (manifest.protocolVersion === 1) return
  if (manifest.minCodevisorVersion !== undefined) {
    if (options.codevisorVersion === undefined) {
      throw new PluginsError(
        "unavailable",
        `Plugin ${manifest.id} requires Codevisor ${manifest.minCodevisorVersion} or newer, but this development build has no version metadata`
      )
    }
    if (compareSemanticVersions(options.codevisorVersion, manifest.minCodevisorVersion) < 0) {
      throw new PluginsError(
        "invalid",
        `Plugin ${manifest.id} requires Codevisor ${manifest.minCodevisorVersion} or newer; this server is ${options.codevisorVersion}`
      )
    }
  }
  const findExecutable = options.findExecutable ?? findExecutableOnPath
  for (const requirement of manifest.requirements?.executables ?? []) {
    if ((await findExecutable(requirement.name, options.env)) !== undefined) continue
    const guidance = [requirement.installHint, requirement.helpUrl].filter(
      (value): value is string => value !== undefined
    )
    throw new PluginsError(
      "unavailable",
      `Plugin ${manifest.id} requires \`${requirement.name}\`, but Codevisor could not find it on PATH.${
        guidance.length === 0 ? "" : ` ${guidance.join(" ")}`
      }`
    )
  }
}
