import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { PluginsError } from "./plugins-error.js"

export const PLUGIN_AUTHORING_SKILL_DIRECTORY = "create-codevisor-plugin"

/// A packaged skill the tool gateway serves through its `skills` tool.
/// Structurally matches @codevisor/mcp's PackagedSkill without importing it —
/// this package's only workspace dependency stays @codevisor/api.
export interface PluginSkill {
  readonly name: string
  readonly summary: string
  /// The skill's SKILL.md.
  readonly path: string
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

/// The plugin-authoring skill, served by the gateway whenever the plugins
/// feature is available so agents can author plugins without rediscovering
/// the contract.
export const pluginAuthoringSkill = (options: PluginSkillOptions = {}): PluginSkill => ({
  name: PLUGIN_AUTHORING_SKILL_DIRECTORY,
  path: join(skillSourcePath(options), "SKILL.md"),
  summary: "build a Codevisor plugin: a pane, tools, and settings inside Codevisor"
})
