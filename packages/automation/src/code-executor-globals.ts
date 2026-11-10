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
  "const __syncMachine = (args) => {",
  "  const value = typeof args === 'string' || (args && typeof args.machineId === 'string') ? args : args?.machine;",
  "  const machine = value && typeof value === 'object' ? value.machineId : value;",
  "  if (typeof machine !== 'string' || machine === '') throw new Error('Pass a machine: a Machine, its machineId, or its name');",
  "  return machine;",
  "};",
  "const __pendingSyncNote = async (args, info) => {",
  "  if (!args || typeof args.cwd !== 'string') return undefined;",
  "  let syncs;",
  "  try { syncs = __itemsOf(await __callTool('codevisor.workspaces.syncs', {})); } catch { return undefined; }",
  "  const sync = syncs.find((item) => item?.machine?.machineId === info.machineId && typeof item.path === 'string' && (args.cwd === item.path || args.cwd.startsWith(item.path + '/')));",
  "  if (!sync || sync.pendingChanges !== true) return undefined;",
  "  return 'Some of your edits had not reached ' + (info.name ?? info.machineId) + ' when this ran; call workspace.waitForSync first next time';",
  "};",
  "const __machineExec = async (args, target, info) => {",
  "  const note = await __pendingSyncNote(args, info);",
  "  const result = await __callTool('codevisor.shell.exec', args, target);",
  "  return note === undefined || !result || typeof result !== 'object' ? result : { ...result, syncPending: note };",
  "};",
  "const __makeMachine = (info) => {",
  "  const isCurrent = info.isCurrent === true || info.machineId === __currentMachineInfo.machineId;",
  "  const target = isCurrent ? undefined : { machine: info.machineId, ...(typeof info.name === 'string' ? { machineName: info.name } : {}) };",
  "  return __hidden({ ...info, isCurrent }, {",
  "    tools: __makeToolsProxy([], target),",
  "    clients: __makeClients(target, { machineId: info.machineId, name: info.name }),",
  "    agents: __makeToolsProxy(['codevisor', 'agents'], target),",
  "    exec: (args = {}) => __machineExec(args, target, info),",
  "    readFile: (args = {}) => __callTool('codevisor.files.read', typeof args === 'string' ? { path: args } : args, target),",
  "    taskStop: (args = {}) => __callTool('codevisor.shell.task_stop', typeof args === 'string' ? { taskId: args } : args, target)",
  "  });",
  "};",
  "const __machineLabel = (machine) => (machine.name ?? machine.machineId) + ' (' + machine.machineId + ')';",
  "const __listMachines = async (internal) => __itemsOf(await __callTool('codevisor.machines.list', {}, internal ? { internal: true } : undefined)).filter((raw) => raw && typeof raw === 'object' && typeof raw.machineId === 'string').map(__makeMachine);",
  "const machines = {",
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
  "  syncs: async () => ({ items: __itemsOf(await __callTool('codevisor.workspaces.syncs', {})) }),",
  "  startSync: (args) => __callTool('codevisor.workspaces.sync_start', { machine: __syncMachine(args) }),",
  "  syncStatus: (args) => __callTool('codevisor.workspaces.sync_status', { machine: __syncMachine(args) }),",
  "  waitForSync: (args) => __callTool('codevisor.workspaces.sync_wait', { machine: __syncMachine(args), ...(typeof args?.timeoutMs === 'number' ? { timeoutMs: args.timeoutMs } : {}) }),",
  "  stopSync: (args) => __callTool('codevisor.workspaces.sync_stop', { machine: __syncMachine(args) })",
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
  "    workflow: 'Call a tool match on its machine: (await machines.get(item.machine.machineId)).tools[item.path](args).'",
  "  };",
  "};"
]

export const codevisorSandboxSignatures = `declare const machines: {
  current: Machine // the machine this chat runs on
  list(): Promise<{ items: Machine[] }>
  get(idOrName: string): Promise<Machine> // machineId, exact name, or unique prefix; throws if none or ambiguous
}
interface Machine {
  machineId: string; name: string; os?: string; online: boolean; lastSeen?: string; isCurrent: boolean
  tools: {
    search(input: { query: string; limit?: number; machines?: "all" }): Promise<{ items: SearchItem[]; total: number }>
    describe: { tool(input: { path: string }): Promise<Tool> }
    [server: string]: { [tool: string]: (args?: object) => Promise<any> } // machine.tools[path](args) or machine.tools.server.tool(args)
  }
  agents: { [tool: string]: (args?: object) => Promise<any>; debug: { [tool: string]: (args?: object) => Promise<any> } } // machine.agents.start(args) is machine.tools.codevisor.agents.start(args)
  clients: { list(): Promise<{ items: Client[] }> } // Codevisor app windows attached to that machine
  exec(args: { command: string; description?: string; timeout?: number; run_in_background?: boolean; cwd?: string }): Promise<{ exitCode: number | null; output: string; timedOut: boolean; durationMs: number; outputPath: string; syncPending?: string } | { taskId: string; outputPath: string }> // a shell command on that machine; timeout ms (default 120000, max 600000); background tasks send an exec.task_finished event
  readFile(args: string | { path: string; offset?: number; limit?: number }): Promise<{ content: string; startLine: number; endLine: number; totalLines: number }>
  taskStop(args: string | { taskId: string }): Promise<object>
}
declare const workspace: { // this chat's workspace, synced one way to other machines
  startSync(machine: Machine | string): Promise<WorkspaceSync> // keeps syncing in the background until stopSync or archive
  syncStatus(machine: Machine | string): Promise<WorkspaceSync>
  waitForSync(machine: Machine | string | { machine: Machine | string; timeoutMs?: number }): Promise<WorkspaceSync & { timedOut: boolean }>
  stopSync(machine: Machine | string): Promise<{ stopped: true }> // also deletes the copy on that machine
  syncs(): Promise<{ items: WorkspaceSync[] }>
}
interface WorkspaceSync {
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
  viewing?: { workspaceId?: string; agentId?: string; page?: string; panes?: object[] } // panes: the selected tab's panes
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
    name: "machines.current",
    signature: "machines.current: Machine",
    description:
      "The machine this chat runs on. Every call goes through a machine: machines.current.tools.<server>.<tool>(args), machines.current.agents.start(args), machines.current.clients.list()."
  },
  {
    name: "machines.get",
    signature: "machines.get(idOrName: string): Promise<Machine>",
    description:
      "Another of the user's machines by machineId, exact name, or unique name prefix, to run its tools or start agents there."
  },
  {
    name: "machines.list",
    signature: "machines.list(): Promise<{ items: Machine[] }>",
    description:
      "Every machine on the user's account with machineId, name, os, online, and lastSeen."
  },
  {
    name: "machine.agents",
    signature: "machine.agents.<tool>(args) and machine.agents.debug.<tool>(args)",
    description:
      "Start and coordinate other agents on that machine: start, message, status, list, answer, cancel, close, subscribe, wait; debug.search and debug.item read transcripts. Same as machine.tools.codevisor.agents.*.",
    gate: "codevisor"
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
      "Run shell commands on any of the user's machines, read files there, and stop background tasks. Pass a workspace sync's path as cwd to run against your workspace.",
    gate: "codevisor"
  },
  {
    name: "workspace.startSync",
    signature:
      "workspace.startSync(machine), workspace.syncStatus(machine), workspace.waitForSync(machine), workspace.stopSync(machine), workspace.syncs()",
    description:
      "Sync this chat's workspace one way to another machine in the background so commands there see your edits; stopSync deletes the copy.",
    gate: "codevisor"
  },
  {
    name: "status",
    signature: "status(text: string): void",
    description: "Show a live progress label to the user; call it before slow steps."
  }
]
