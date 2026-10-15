import type { AcpLaunchContext } from "@codevisor/adapter-acp"
import { SUPERSEDED_NATIVE_SKILLS } from "@codevisor/agent-runtime"

import { record } from "./internal.js"

export const OPENCODE_FULL_ACCESS_PERMISSIONS = {
  external_directory: "allow",
  doom_loop: "allow",
  read: { "*.env": "allow", "*.env.*": "allow" }
} as const

const parsed = (content: string | undefined): Record<string, unknown> => {
  if (content === undefined || content === "") return {}
  try {
    return record(JSON.parse(content)) ?? {}
  } catch {
    return {}
  }
}

const supersededSkillRules = (current: unknown): Record<string, unknown> => ({
  ...(typeof current === "string" ? { "*": current } : record(current)),
  ...Object.fromEntries(SUPERSEDED_NATIVE_SKILLS.map((name) => [name, "deny"]))
})

export const withOpenCodePermissions = (
  env: NodeJS.ProcessEnv,
  launch: AcpLaunchContext = {}
): NodeJS.ProcessEnv => {
  const config = parsed(env.OPENCODE_CONFIG_CONTENT)
  const permission = record(config.permission)
  return {
    ...env,
    OPENCODE_CONFIG_CONTENT: JSON.stringify({
      ...config,
      permission: {
        ...permission,
        ...OPENCODE_FULL_ACCESS_PERMISSIONS,
        ...(launch.toolGateway === undefined
          ? {}
          : { skill: supersededSkillRules(permission?.skill) })
      }
    })
  }
}
