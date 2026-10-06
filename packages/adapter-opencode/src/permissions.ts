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

/// `env` with the full-access rules added to the config OpenCode reads from
/// the environment, keeping whatever else that config already holds.
export const withOpenCodePermissions = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => {
  const config = parsed(env.OPENCODE_CONFIG_CONTENT)
  return {
    ...env,
    OPENCODE_CONFIG_CONTENT: JSON.stringify({
      ...config,
      permission: { ...record(config.permission), ...OPENCODE_FULL_ACCESS_PERMISSIONS }
    })
  }
}
