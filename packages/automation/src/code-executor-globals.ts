export const sandboxErrorSource: ReadonlyArray<string> = [
  "class MachineUnavailableError extends Error {",
  "  constructor(message, details = {}) { super(message); this.name = 'MachineUnavailableError'; this.code = 'machine_unavailable'; this.details = details; this.machineId = details.machineId; this.machineName = details.name; this.lastSeen = details.lastSeen; this.phase = details.phase; }",
  "}",
  "class ClientUnavailableError extends Error {",
  "  constructor(message, details = {}) { super(message); this.name = 'ClientUnavailableError'; this.code = 'client_unavailable'; this.details = details; this.clientId = details.clientId; this.clientName = details.name; this.lastSeen = details.lastSeen; this.phase = details.phase; }",
  "}",
  "const __typedToolError = (error) => {",
  "  if (!error || typeof error !== 'object' || typeof error.code !== 'string') return error;",
  "  let details;",
  "  try { details = typeof error.detailsJson === 'string' ? JSON.parse(error.detailsJson) : undefined; } catch { details = undefined; }",
  "  if (error.code === 'machine_unavailable') return new MachineUnavailableError(error.message, details ?? {});",
  "  if (error.code === 'client_unavailable') return new ClientUnavailableError(error.message, details ?? {});",
  "  const plain = new Error(error.message);",
  "  plain.code = error.code;",
  "  if (details !== undefined) plain.details = details;",
  "  return plain;",
  "};"
]

export const machinesAndClientsSource: ReadonlyArray<string> = [
  "const status = (text) => { __statusBridge(text === undefined || text === null ? '' : __format(text)); };",
  "const __hidden = (object, values) => { for (const [key, value] of Object.entries(values)) Object.defineProperty(object, key, { value, enumerable: false, configurable: true }); return object; };",
  "const __itemsOf = (raw) => raw && typeof raw === 'object' && Array.isArray(raw.items) ? raw.items : [];",
  "const __currentMachineInfo = { machineId: typeof __context.machine?.id === 'string' ? __context.machine.id : 'local', name: typeof __context.machine?.name === 'string' ? __context.machine.name : 'This machine' };",
  "const __makeClient = (raw, target, machineInfo) => {",
  "  const clientId = raw.clientId;",
  "  const isOrigin = typeof raw.isOrigin === 'boolean' ? raw.isOrigin : typeof __context.originClientId === 'string' && clientId === __context.originClientId;",
  "  return __hidden({ ...raw, clientId, machine: raw.machine ?? machineInfo, isOrigin }, {",
  "    context: () => __callTool('codevisor.clients.context', { clientId }, target),",
  "    navigate: (args = {}) => __callTool('codevisor.clients.navigate', { ...args, clientId }, target),",
  "    layout: (args = {}) => __callTool('codevisor.clients.layout', { ...args, clientId }, target),",
  "    openPage: (args = {}) => __callTool('codevisor.clients.open_page', { clientId, body: args }, target),",
  "    window: (args = {}) => __callTool('codevisor.clients.window', { clientId, body: args }, target)",
  "  });",
  "};",
  "const __makeClients = (target, machineInfo) => ({ list: async () => ({ items: __itemsOf(await __callTool('codevisor.clients.list', {}, target)).filter((raw) => raw && typeof raw === 'object').map((raw) => __makeClient(raw, target, machineInfo)) }) });",
  "const __mirrorMachine = (args) => {",
  "  const value = typeof args === 'string' || (args && typeof args.machineId === 'string') ? args : args?.machine;",
  "  const machine = value && typeof value === 'object' ? value.machineId : value;",
  "  if (typeof machine !== 'string' || machine === '') throw new Error('Pass a machine: a Machine, its machineId, or its name');",
  "  return machine;",
  "};",
  "const __pendingMirrorNote = async (args, info) => {",
  "  if (!args || typeof args.cwd !== 'string') return undefined;",
  "  let mirrors;",
  "  try { mirrors = __itemsOf(await __callTool('codevisor.workspaces.mirrors', {})); } catch { return undefined; }",
  "  const mirror = mirrors.find((item) => item?.machine?.machineId === info.machineId && typeof item.path === 'string' && (args.cwd === item.path || args.cwd.startsWith(item.path + '/')));",
  "  if (!mirror || mirror.pendingChanges !== true) return undefined;",
  "  return 'Some of your edits had not reached ' + (info.name ?? info.machineId) + ' when this ran; call workspace.waitForMirror first next time';",
  "};",
  "const __machineExec = async (args, target, info) => {",
  "  const note = await __pendingMirrorNote(args, info);",
  "  const result = await __callTool('codevisor.shell.exec', args, target);",
  "  return note === undefined || !result || typeof result !== 'object' ? result : { ...result, mirrorBehind: note };",
  "};",
  "const __makeMachine = (info) => {",
  "  const isCurrent = info.isCurrent === true || info.machineId === __currentMachineInfo.machineId;",
  "  const target = isCurrent ? undefined : { machine: info.machineId, ...(typeof info.name === 'string' ? { machineName: info.name } : {}) };",
  "  return __hidden({ ...info, isCurrent }, {",
  "    tools: __makeToolsProxy([], target),",
  "    clients: __makeClients(target, { machineId: info.machineId, name: info.name }),",
  "    exec: (args = {}) => __machineExec(args, target, info),",
  "    readFile: (args = {}) => __callTool('codevisor.files.read', typeof args === 'string' ? { path: args } : args, target),",
  "    taskStop: (args = {}) => __callTool('codevisor.shell.task_stop', typeof args === 'string' ? { taskId: args } : args, target)",
  "  });",
  "};",
  "const __machineLabel = (machine) => (machine.name ?? machine.machineId) + ' (' + machine.machineId + ')';",
  "const __listMachines = async (internal) => __itemsOf(await __callTool('codevisor.machines.list', {}, internal ? { internal: true } : undefined)).filter((raw) => raw && typeof raw === 'object' && typeof raw.machineId === 'string').map(__makeMachine);",
  "const __machinesCore = {",
  "  current: __makeMachine({ ...__currentMachineInfo, isCurrent: true }),",
  "  list: async () => ({ items: await __listMachines(false) }),",
  "  get: async (query) => {",
  "    const wanted = __stringMatcher(query, 'machine id or name').trim();",
  "    const lower = wanted.toLowerCase();",
  "    const all = await __listMachines(true);",
  "    const byId = all.find((machine) => machine.machineId === wanted);",
  "    if (byId) return byId;",
  "    const named = all.filter((machine) => String(machine.name ?? '').toLowerCase() === lower);",
  "    const matches = named.length > 0 ? named : all.filter((machine) => String(machine.name ?? '').toLowerCase().startsWith(lower) || machine.machineId.toLowerCase().startsWith(lower));",
  "    if (matches.length === 1) return matches[0];",
  "    if (matches.length === 0) throw new Error('No machine matches \"' + wanted + '\". Machines: ' + (all.map(__machineLabel).join(', ') || 'none'));",
  "    throw new Error('\"' + wanted + '\" matches several machines: ' + matches.map(__machineLabel).join(', ') + '. Pass a machine id.');",
  "  }",
  "};",
  "const workspace = {",
  "  mirrors: async () => ({ items: __itemsOf(await __callTool('codevisor.workspaces.mirrors', {})) }),",
  "  startMirror: (args) => __callTool('codevisor.workspaces.mirror_start', { machine: __mirrorMachine(args) }),",
  "  mirrorStatus: (args) => __callTool('codevisor.workspaces.mirror_status', { machine: __mirrorMachine(args) }),",
  "  waitForMirror: (args) => __callTool('codevisor.workspaces.mirror_wait', { machine: __mirrorMachine(args), ...(typeof args?.timeoutMs === 'number' ? { timeoutMs: args.timeoutMs } : {}) }),",
  "  stopMirror: (args) => __callTool('codevisor.workspaces.mirror_stop', { machine: __mirrorMachine(args) })",
  "};",
  "const __searchTools = async (args = {}) => {",
  "  const { machines: scope, ...query } = args && typeof args === 'object' ? args : {};",
  "  if (scope !== 'all') return __callTool('search', query);",
  "  const listed = await __listMachines(true);",
  "  const targets = listed.some((machine) => machine.isCurrent) ? listed : [machines.current, ...listed];",
  "  const settled = await Promise.all(targets.map(async (machine) => {",
  "    if (!machine.isCurrent && machine.online === false) return { machine, error: 'offline' };",
  "    try { return { machine, result: machine.isCurrent ? await __callTool('search', query) : await machine.tools.search(query) }; } catch (error) { return { machine, error: error && typeof error.message === 'string' ? error.message : String(error) }; }",
  "  }));",
  "  const tag = (machine) => ({ machineId: machine.machineId, name: machine.name });",
  "  const items = settled.flatMap((entry) => entry.result && Array.isArray(entry.result.items) ? entry.result.items.map((item) => ({ ...item, machine: tag(entry.machine) })) : []).sort((left, right) => (right.score ?? 0) - (left.score ?? 0));",
  "  const unavailable = settled.filter((entry) => entry.error !== undefined).map((entry) => ({ machine: tag(entry.machine), error: entry.error }));",
  "  const limit = typeof query.limit === 'number' ? Math.max(1, Math.min(query.limit, 50)) : 12;",
  "  return {",
  "    items: items.slice(0, limit),",
  "    total: settled.reduce((sum, entry) => sum + (typeof entry.result?.total === 'number' ? entry.result.total : 0), 0),",
  "    ...(unavailable.length === 0 ? {} : { unavailable }),",
  "    workflow: 'Call a tool match on its machine: (await machines.get(item.machine.machineId)).tools[item.path](args). A Codevisor tool (server codevisor) is a global: call it as its path reads with machine: item.machine.machineId.'",
  "  };",
  "};"
]

export const codevisorSandboxSignatures = `declare const agents: {
  start(args: { title: string; prompt: string; checkout?: "worktree" | "shared" | "project" | "none"; sandbox?: string; machine?: MachineRef; harness?: string; model?: string; project?: string; labels?: Record<string, string> }): Promise<Agent> // checkout: worktree = new git worktree + workspace, shared = your own workspace and files (your machine only), project = the project folder in a new workspace, none = an empty folder with no project; sandbox (a profile) instead of checkout and machine runs it on a new sandbox
  get(agentIdOrArgs: string | { agentId: string; machine?: MachineRef }): Promise<Agent> // finds it on any of your online machines when machine is left out
  list(args?: { state?: string; project?: string; label?: string; createdByAgentId?: string; machine?: MachineRef; next?: string }): Promise<{ items: Agent[]; next?: string }>
  [tool: string]: (args?: { machine?: MachineRef; [key: string]: any }) => Promise<any> // message, status, answer, cancel, wait, close, subscribe, debug.*: the same tools by agentId
}
interface Agent {
  agentId: string; title: string; machine: { machineId: string; name: string }; workspaceId?: string; [field: string]: any
  message(args: string | { text: string; delivery?: "steer" | "queue" }): Promise<object>; status(): Promise<object>; answer(args: object): Promise<object>; cancel(): Promise<object>
  wait(args?: { until?: string[]; timeoutMs?: number }): Promise<object>; close(): Promise<object>; debug: { [tool: string]: (args?: object) => Promise<any> }
}
type MachineRef = string | Machine // a machineId or name; default: the machine this chat runs on
// Every other Codevisor tool group is a global too, like plugins, bots, sandboxes, projects, workspaces, harnesses, skills, terminals, events, jobs, messages, context.
// Tools that act on one machine take an optional machine; tools shared by your machines (plugins, sandboxes, machines.*) and tools about this chat (context, events, jobs, messages) take none.
declare const machines: {
  current: Machine // the machine this chat runs on
  list(): Promise<{ items: Machine[] }>
  get(idOrName: string): Promise<Machine> // machineId, exact name, or unique prefix; throws if none or ambiguous
  [tool: string]: (args?: object) => Promise<any> // add, invite, remove, roles, ...
}
interface Machine {
  machineId: string; name: string; os?: string; online: boolean; lastSeen?: string; isCurrent: boolean
  tools: {
    search(input: { query: string; limit?: number; machines?: "all" }): Promise<{ items: SearchItem[]; total: number }>
    describe: { tool(input: { path: string }): Promise<Tool> }
    [server: string]: { [tool: string]: (args?: object) => Promise<any> } // plugin and MCP tools on that machine: machine.tools[path](args) or machine.tools.server.tool(args)
  }
  clients: { list(): Promise<{ items: Client[] }> } // Codevisor app windows attached to that machine
  exec(args: { command: string; description?: string; timeout?: number; run_in_background?: boolean; cwd?: string }): Promise<{ exitCode: number | null; output: string; timedOut: boolean; durationMs: number; outputPath: string; mirrorBehind?: string } | { taskId: string; outputPath: string }> // a shell command on that machine; timeout ms (default 120000, max 600000); background tasks send an exec.task_finished event
  readFile(args: string | { path: string; offset?: number; limit?: number }): Promise<{ content: string; startLine: number; endLine: number; totalLines: number }>
  taskStop(args: string | { taskId: string }): Promise<object>
}
declare const workspace: { // this chat's workspace; a mirror is a one-way, kept-current copy of it on another machine
  startMirror(machine: Machine | string): Promise<WorkspaceMirror> // keeps syncing in the background until stopMirror or archive
  mirrorStatus(machine: Machine | string): Promise<WorkspaceMirror>
  waitForMirror(machine: Machine | string | { machine: Machine | string; timeoutMs?: number }): Promise<WorkspaceMirror & { timedOut: boolean }>
  stopMirror(machine: Machine | string): Promise<{ stopped: true }> // also deletes the mirror on that machine
  mirrors(): Promise<{ items: WorkspaceMirror[] }>
}
interface WorkspaceMirror {
  machine: { machineId: string; name: string }; path?: string; state: "syncing" | "synced" | "failed"; pendingChanges: boolean
  lastSyncedAt?: string; lastSync?: { files: number; bytes: number; ms: number }; skipped: string[]; error?: string
}
type SearchItem =
  | { kind: "tool"; path: string; name: string; description?: string; machine?: { machineId: string; name: string } }
  | { kind: "skill"; name: string; description: string } // read it with the skills tool
  | { kind: "global"; name: string; signature: string; description: string }
declare function status(text: string): void // live progress label shown to the user; call before slow steps
interface Client {
  clientId: string; name: string; platform: "macos" | "ios"; machine: { machineId: string; name: string }
  online?: boolean; isActive?: boolean; lastActiveAt?: string; isOrigin: boolean // isOrigin: the window that sent this prompt; false for every client when an automation or another agent sent it
  viewing?: { workspaceId?: string; agentId?: string; page?: string; panes?: object[]; layoutActions?: string[] } // panes: the selected tab's panes; layoutActions: what layout() takes there (a bot conversation: splits only)
  context(): Promise<object>; navigate(args: object): Promise<object>; openPage(args: object): Promise<object>; layout(args: object): Promise<object>; window(args: object): Promise<object>
}
declare class MachineUnavailableError extends Error { machineId: string; machineName?: string; lastSeen?: string; phase: "before-send" | "in-flight" } // in-flight: the call may or may not have completed; never retried automatically
declare class ClientUnavailableError extends Error { clientId: string; clientName?: string; phase: "before-send" | "in-flight" }`

export interface SandboxGlobal {
  readonly name: string
  readonly signature: string
  readonly description: string
  readonly gate?: "codevisor"
}

export const SANDBOX_GLOBALS: ReadonlyArray<SandboxGlobal> = [
  {
    name: "agents",
    signature:
      "agents.start({ title, prompt, checkout, machine? }), agents.get(agentId), agents.list({ machine? })",
    description:
      "Start and coordinate other agents on any of the user's machines. Returns agent objects that know their machine: agent.message(text), agent.status(), agent.answer(args), agent.cancel(), agent.wait(), agent.close(), agent.debug.*.",
    gate: "codevisor"
  },
  {
    name: "codevisor",
    signature:
      "plugins.*, bots.*, sandboxes.*, projects.*, workspaces.*, harnesses.*, events.*, jobs.*, context.current(), ...",
    description:
      "Codevisor's own tools are globals named by group. Tools that act on one machine take an optional machine (an id or name; default: this one); plugins, sandboxes, machines.* and tools about this chat take none.",
    gate: "codevisor"
  },
  {
    name: "machines.current",
    signature: "machines.current: Machine",
    description:
      "The machine this chat runs on: machines.current.tools.<server>.<tool>(args) for plugin and MCP tools, machines.current.exec(args), machines.current.clients.list()."
  },
  {
    name: "machines.get",
    signature: "machines.get(idOrName: string): Promise<Machine>",
    description:
      "Another of the user's machines by machineId, exact name, or unique name prefix, to run commands or plugin tools there. Pass it, or its name, as machine to Codevisor tools."
  },
  {
    name: "machines.list",
    signature: "machines.list(): Promise<{ items: Machine[] }>",
    description:
      "Every machine on the user's account with machineId, name, os, online, and lastSeen."
  },
  {
    name: "machine.clients",
    signature: "machine.clients.list(): Promise<{ items: Client[] }>",
    description:
      "The Codevisor app windows attached to that machine, to see what they show or open a chat, page, or layout.",
    gate: "codevisor"
  },
  {
    name: "machine.exec",
    signature:
      "machine.exec({ command, description?, timeout?, run_in_background?, cwd? }), machine.readFile(path), machine.taskStop(taskId)",
    description:
      "Run shell commands on any of the user's machines, read files there, and stop background tasks. Pass a workspace mirror's path as cwd to run against your workspace.",
    gate: "codevisor"
  },
  {
    name: "workspace.startMirror",
    signature:
      "workspace.startMirror(machine), workspace.mirrorStatus(machine), workspace.waitForMirror(machine), workspace.stopMirror(machine), workspace.mirrors()",
    description:
      "Mirror this chat's workspace one way to another machine, kept current in the background so commands there see your edits; stopMirror deletes the mirror.",
    gate: "codevisor"
  },
  {
    name: "status",
    signature: "status(text: string): void",
    description: "Show a live progress label to the user; call it before slow steps."
  }
]
