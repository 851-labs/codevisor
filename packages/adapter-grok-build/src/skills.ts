import { readFileSync } from "node:fs"
import { join } from "node:path"

import type { AcpLaunchContext } from "@codevisor/adapter-acp"
import { SUPERSEDED_NATIVE_SKILLS } from "@codevisor/agent-runtime"
import { parse as parseToml } from "smol-toml"

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined

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
    // Grok ignores a config it can't parse too.
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

export const readGrokConfigFile = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

/// Grok reads Claude's skill folders, including the claude.ai skills for
/// Claude's own browser and desktop tools. With Codevisor's gateway attached
/// they are disabled through Grok's `GROK_CONFIG` overlay, which then keeps
/// them out of the model's prompt and the advertised commands. The overlay
/// replaces arrays wholesale, so it carries the `skills.disabled` names the
/// user and managed configs (and any existing overlay) already set.
export const withGrokSkillsDisabled = (
  env: NodeJS.ProcessEnv,
  launch: AcpLaunchContext,
  readFile: (path: string) => string | undefined = readGrokConfigFile
): NodeJS.ProcessEnv => {
  if (launch.toolGateway === undefined) return env
  const home = env.GROK_HOME ?? (env.HOME === undefined ? undefined : join(env.HOME, ".grok"))
  const overlay = jsonObject(env.GROK_CONFIG)
  const disabled = new Set([
    ...(home === undefined
      ? []
      : ["managed_config.toml", "config.toml"].flatMap((file) =>
          disabledSkills(tomlFile(join(home, file), readFile))
        )),
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
