import type { AcpLaunchContext } from "@codevisor/adapter-acp"
import { SUPERSEDED_NATIVE_SKILLS } from "@codevisor/agent-runtime"

/// OpenCode allows every tool by default but asks before touching paths
/// outside the chat's folder, repeating an identical tool call, or reading
/// `.env` files. Codevisor runs harnesses with full access, so chats launch
/// with exactly those rules allowed. Nothing broader: OpenCode applies these
/// after its agents' own rules, so a blanket allow would also lift plan
/// mode's ban on edits and the limits on its subagents.
///
/// OpenCode 1's `permission` key, which OpenCode 2 migrates to its own rules.
export const OPENCODE_FULL_ACCESS_PERMISSIONS = {
  external_directory: "allow",
  doom_loop: "allow",
  read: { "*.env": "allow", "*.env.*": "allow" }
} as const

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined

const parsed = (content: string | undefined): Record<string, unknown> => {
  if (content === undefined || content === "") return {}
  try {
    return record(JSON.parse(content)) ?? {}
  } catch {
    // OpenCode ignores a malformed document too.
    return {}
  }
}

/// OpenCode reads Claude's skill folders, including the claude.ai skills for
/// Claude's own browser and desktop tools. With Codevisor's gateway attached
/// those are denied: OpenCode then leaves them out of what the model sees.
const supersededSkillRules = (current: unknown): Record<string, unknown> => ({
  // A bare action ("ask") is OpenCode's shorthand for every skill.
  ...(typeof current === "string" ? { "*": current } : record(current)),
  ...Object.fromEntries(SUPERSEDED_NATIVE_SKILLS.map((name) => [name, "deny"]))
})

/// `env` with the full-access rules added to the config OpenCode reads from
/// the environment, keeping whatever else that config already holds.
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
