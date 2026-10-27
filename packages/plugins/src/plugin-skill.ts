import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

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

export const pluginAuthoringSkill = (options: PluginSkillOptions = {}): PluginSkill => ({
  name: PLUGIN_AUTHORING_SKILL_DIRECTORY,
  path: join(skillSourcePath(options), "SKILL.md"),
  summary: "build a Codevisor plugin: an MCP server with tools, events, skills, apps and panes",
  composer: "Build a Codevisor plugin: an MCP server with tools, events, skills or UI"
})

const skillSourcePath = (options: PluginSkillOptions): string => {
  const found = skillCandidates(options).find((candidate) =>
    existsSync(join(candidate, "SKILL.md"))
  )
  if (found === undefined) throw new Error("Missing packaged create-codevisor-plugin skill")
  return found
}

const skillCandidates = (options: PluginSkillOptions): ReadonlyArray<string> => {
  /* v8 ignore next */
  const moduleDirectory = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  const relative = join("skills", PLUGIN_AUTHORING_SKILL_DIRECTORY)
  return [
    join(moduleDirectory, "..", "resources", relative),
    join(workingDirectory, "packages", "plugins", "resources", relative)
  ]
}
