const renamedPluginTools = [
  "connect",
  "detect_auth",
  "list",
  "machine_set_enabled",
  "machine_state",
  "oauth_disconnect",
  "oauth_start",
  "project_enable",
  "session_enable",
  "tools",
  "update"
] as const

export const CODEVISOR_TOOL_ALIASES: ReadonlyMap<string, string> = new Map([
  ...renamedPluginTools.map((name) => [`mcps.${name}`, `plugins.${name}`] as const),
  ["mcps.create", "plugins.add_custom"],
  ["mcps.delete", "plugins.remove"]
])

export const codevisorToolName = (name: string): string => CODEVISOR_TOOL_ALIASES.get(name) ?? name
