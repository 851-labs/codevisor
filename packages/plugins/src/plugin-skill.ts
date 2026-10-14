import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { PluginsError } from "./plugins-error.js"

export const PLUGIN_AUTHORING_SKILL_DIRECTORY = "create-codevisor-plugin"

export interface PluginSkill {
  readonly name: string
  readonly summary: string
  readonly path: string
  readonly composer?: string
}

export interface PluginSkillOptions {
  readonly moduleDirectory?: string
  readonly workingDirectory?: string
}

const skillSourcePath = (options: PluginSkillOptions): string => {
  /* v8 ignore next */
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

export const pluginAuthoringSkill = (options: PluginSkillOptions = {}): PluginSkill => ({
  name: PLUGIN_AUTHORING_SKILL_DIRECTORY,
  path: join(skillSourcePath(options), "SKILL.md"),
  summary: "build a Codevisor plugin: a pane, tools, and settings inside Codevisor",
  composer: "Build a Codevisor plugin: a pane, tools, or settings"
})
