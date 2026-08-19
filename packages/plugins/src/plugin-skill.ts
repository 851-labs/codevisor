import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { PluginsError } from "./plugins-error.js"

export const PLUGIN_AUTHORING_SKILL_DIRECTORY = "create-codevisor-plugin"

/// Structurally matches @codevisor/skills ManagedSkillSpec without importing
/// it — this package's only workspace dependency stays @codevisor/api.
export interface PluginSkillSpec {
  readonly directoryName: string
  readonly sourcePath: string
  readonly enabled: boolean
}

export interface PluginSkillOptions {
  /// Test seams; production resolves relative to this module and the cwd.
  readonly moduleDirectory?: string
  readonly workingDirectory?: string
}

/// Locates the packaged create-codevisor-plugin skill. The resources tree has
/// one logical root across layouts: packages/plugins/{src,dist}/*.js next to
/// packages/plugins/resources in the repo and in the packaged runtime alike,
/// with a cwd fallback for test runners that execute from the repo root.
const skillSourcePath = (options: PluginSkillOptions): string => {
  /* v8 ignore next -- production resolves from this module's real location. */
  const moduleDirectory = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  const relative = join("skills", PLUGIN_AUTHORING_SKILL_DIRECTORY)
  const candidates = [
    join(moduleDirectory, "..", "resources", relative),
    join(workingDirectory, "packages", "plugins", "resources", relative)
  ]
  const found = candidates.find((candidate) => existsSync(join(candidate, "SKILL.md")))
  if (found === undefined) {
    throw new PluginsError("notFound", "Missing packaged create-codevisor-plugin skill")
  }
  return found
}

/// The managed-skill spec for the plugin-authoring skill, synced into every
/// harness's skills directory whenever the plugins feature is available so
/// agents can author plugins without rediscovering the contract. Disabled
/// specs carry no source path — sync then only removes installed copies.
export const managedPluginSkill = (
  enabled: boolean,
  options: PluginSkillOptions = {}
): PluginSkillSpec => ({
  directoryName: PLUGIN_AUTHORING_SKILL_DIRECTORY,
  enabled,
  sourcePath: enabled ? skillSourcePath(options) : ""
})
