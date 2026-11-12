export type CodevisorToolScope = "machine" | "account" | "chat"

export const codevisorToolScopes = (
  names: ReadonlyArray<string>
): Readonly<Record<string, CodevisorToolScope>> =>
  Object.fromEntries(names.filter(isTopLevel).map((name) => [name, scopeOf(name)]))

const onMachineObjects = new Set(["files.read", "machines.list"])
const onMachineObjectGroups = new Set(["shell", "clients"])
const onWorkspaceGlobal = /^workspaces\.mirror/

const chatGroups = new Set(["context", "events", "jobs", "messages", "bot"])
const chatTools = new Set([
  "agents.archive",
  "agents.subscribe",
  "agents.subscriptions",
  "agents.unsubscribe",
  "plugins.request_setup"
])

const accountGroups = new Set(["sandboxes", "machines"])
const machinePluginTools = new Set([
  "plugins.machine_state",
  "plugins.machine_set_enabled",
  "plugins.project_enable",
  "plugins.session_enable"
])

const isTopLevel = (name: string): boolean =>
  !onMachineObjects.has(name) &&
  !onMachineObjectGroups.has(groupOf(name)) &&
  !onWorkspaceGlobal.test(name)

const scopeOf = (name: string): CodevisorToolScope => {
  const group = groupOf(name)
  if (chatGroups.has(group) || chatTools.has(name)) return "chat"
  if (accountGroups.has(group) || isAccountPlugin(name)) return "account"
  return "machine"
}

const isAccountPlugin = (name: string): boolean =>
  groupOf(name) === "plugins" && !machinePluginTools.has(name)

const groupOf = (name: string): string => name.split(".")[0] ?? name
