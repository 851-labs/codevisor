import { readFileSync } from "node:fs"
import { join } from "node:path"

import type { AcpLaunchContext } from "@codevisor/adapter-acp"
import { SUPERSEDED_NATIVE_SKILLS } from "@codevisor/agent-runtime"
import { parse as parseToml } from "smol-toml"

import { objectRecord as record } from "./record.js"

const disabledSkills = (config: Record<string, unknown> | undefined): ReadonlyArray<string> => {
  const disabled = record(config?.skills)?.disabled
  return Array.isArray(disabled)
    ? disabled.filter((name): name is string => typeof name === "string")
    : []
}

const tomlFile = (
  path: string,
  readFile: (path: string) => string | undefined
): Record<string, unknown> | undefined => {
  const content = readFile(path)
  if (content === undefined) return undefined
  try {
    return parseToml(content)
  } catch {
    return undefined
  }
}

const jsonObject = (content: string | undefined): Record<string, unknown> => {
  if (content === undefined || content === "") return {}
  try {
    return record(JSON.parse(content)) ?? {}
  } catch {
    return {}
  }
}

const homeConfigDisabledSkills = (
  home: string | undefined,
  readFile: (path: string) => string | undefined
): ReadonlyArray<string> => {
  if (home === undefined) return []
  return ["managed_config.toml", "config.toml"].flatMap((file) =>
    disabledSkills(tomlFile(join(home, file), readFile))
  )
}

const readGrokConfigFile = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

export const withGrokSkillsDisabled = (
  env: NodeJS.ProcessEnv,
  launch: AcpLaunchContext,
  readFile: (path: string) => string | undefined = readGrokConfigFile
): NodeJS.ProcessEnv => {
  if (launch.toolGateway === undefined) return env
  const home = env.GROK_HOME ?? (env.HOME === undefined ? undefined : join(env.HOME, ".grok"))
  const overlay = jsonObject(env.GROK_CONFIG)
  const disabled = new Set([
    ...homeConfigDisabledSkills(home, readFile),
    ...disabledSkills(overlay),
    ...SUPERSEDED_NATIVE_SKILLS
  ])
  return {
    ...env,
    GROK_CONFIG: JSON.stringify({
      ...overlay,
      skills: { ...record(overlay.skills), disabled: [...disabled] }
    })
  }
}
