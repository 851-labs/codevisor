/// Sandbox globals beyond `tools`: typed tool errors, `status`, `machines`,
/// `clients`, and the cross-machine `tools.search`, as prelude source lines
/// spliced into buildExecutionSource. Their model-facing signatures live
/// beside them so the docs and the prelude change together.

/// Typed tool failures. The host bridge rejects with an Error carrying `code`
/// and `detailsJson`; these rebuild the named classes sandbox code can catch.
/// The Error `name` is the class name, so the machine or client display name
/// lives in `machineName` / `clientName` (and in `details.name`).
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

/// `status`, `machines`, `clients`, and the cross-machine `tools.search`.
/// Machine and client handles carry their methods as non-enumerable
/// properties so returning them from a script serializes only the facts.
export const machinesAndClientsSource: ReadonlyArray<string> = [
  "const status = (text) => { __statusBridge(text === undefined || text === null ? '' : __format(text)); };",
  "const __hidden = (object, values) => { for (const [key, value] of Object.entries(values)) Object.defineProperty(object, key, { value, enumerable: false, configurable: true }); return object; };",
  "const __listOf = (raw, key) => Array.isArray(raw) ? raw : raw && typeof raw === 'object' && Array.isArray(raw[key]) ? raw[key] : [];",
  "const __currentMachineInfo = { id: typeof __context.machine?.id === 'string' ? __context.machine.id : 'local', name: typeof __context.machine?.name === 'string' ? __context.machine.name : 'This machine' };",
  "const __makeClient = (raw, target, machineInfo) => {",
  "  const id = typeof raw.id === 'string' ? raw.id : raw.clientId;",
  "  const isOrigin = typeof raw.isOrigin === 'boolean' ? raw.isOrigin : typeof __context.originClientId === 'string' && id === __context.originClientId;",
  "  return __hidden({ ...raw, id, machine: raw.machine ?? machineInfo, isOrigin }, {",
  "    context: () => __callTool('codevisor.clients.context', { clientId: id }, target),",
  "    navigate: (args = {}) => __callTool('codevisor.clients.navigate', { ...args, clientId: id }, target),",
  "    layout: (args = {}) => __callTool('codevisor.clients.layout', { ...args, clientId: id }, target),",
  "    openPage: (args = {}) => __callTool('codevisor.clients.open_page', { clientId: id, body: args }, target),",
  "    window: (args = {}) => __callTool('codevisor.clients.window', { clientId: id, body: args }, target)",
  "  });",
  "};",
  "const __makeClients = (target, machineInfo) => ({ list: async () => __listOf(await __callTool('codevisor.clients.list', {}, target), 'clients').filter((raw) => raw && typeof raw === 'object').map((raw) => __makeClient(raw, target, machineInfo)) });",
  "const clients = __makeClients(undefined, __currentMachineInfo);",
  "const __makeMachine = (info) => {",
  "  const isCurrent = info.isCurrent === true || info.id === __currentMachineInfo.id;",
  "  const target = isCurrent ? undefined : { machine: info.id, ...(typeof info.name === 'string' ? { machineName: info.name } : {}) };",
  "  return __hidden({ ...info, isCurrent }, { tools: isCurrent ? tools : __makeToolsProxy([], target), clients: isCurrent ? clients : __makeClients(target, { id: info.id, name: info.name }) });",
  "};",
  "const __machineLabel = (machine) => (machine.name ?? machine.id) + ' (' + machine.id + ')';",
  "const __listMachines = async (internal) => __listOf(await __callTool('codevisor.machines.list', {}, internal ? { internal: true } : undefined), 'machines').filter((raw) => raw && typeof raw === 'object' && typeof raw.id === 'string').map(__makeMachine);",
  "const machines = {",
  "  current: __makeMachine({ ...__currentMachineInfo, isCurrent: true }),",
  "  list: () => __listMachines(false),",
  "  get: async (query) => {",
  "    const wanted = __stringMatcher(query, 'machine id or name').trim();",
  "    const lower = wanted.toLowerCase();",
  "    const all = await __listMachines(true);",
  "    const byId = all.find((machine) => machine.id === wanted);",
  "    if (byId) return byId;",
  "    const named = all.filter((machine) => String(machine.name ?? '').toLowerCase() === lower);",
  "    const matches = named.length > 0 ? named : all.filter((machine) => String(machine.name ?? '').toLowerCase().startsWith(lower) || machine.id.toLowerCase().startsWith(lower));",
  "    if (matches.length === 1) return matches[0];",
  "    if (matches.length === 0) throw new Error('No machine matches \"' + wanted + '\". Machines: ' + (all.map(__machineLabel).join(', ') || 'none'));",
  "    throw new Error('\"' + wanted + '\" matches several machines: ' + matches.map(__machineLabel).join(', ') + '. Pass a machine id.');",
  "  }",
  "};",
  "const __searchTools = async (args = {}) => {",
  "  const { machines: scope, ...query } = args && typeof args === 'object' ? args : {};",
  "  if (scope !== 'all') return __callTool('search', query);",
  "  const listed = await __listMachines(true);",
  "  const targets = listed.some((machine) => machine.isCurrent) ? listed : [machines.current, ...listed];",
  "  const settled = await Promise.all(targets.map(async (machine) => {",
  "    if (!machine.isCurrent && machine.online === false) return { machine, error: 'offline' };",
  "    try { return { machine, result: await machine.tools.search(query) }; } catch (error) { return { machine, error: error && typeof error.message === 'string' ? error.message : String(error) }; }",
  "  }));",
  "  const tag = (machine) => ({ id: machine.id, name: machine.name });",
  "  const items = settled.flatMap((entry) => entry.result && Array.isArray(entry.result.items) ? entry.result.items.map((item) => ({ ...item, machine: tag(entry.machine) })) : []).sort((left, right) => (right.score ?? 0) - (left.score ?? 0));",
  "  const unavailable = settled.filter((entry) => entry.error !== undefined).map((entry) => ({ machine: tag(entry.machine), error: entry.error }));",
  "  const limit = typeof query.limit === 'number' ? Math.max(1, Math.min(query.limit, 50)) : 12;",
  "  return {",
  "    items: items.slice(0, limit),",
  "    total: settled.reduce((sum, entry) => sum + (typeof entry.result?.total === 'number' ? entry.result.total : 0), 0),",
  "    ...(unavailable.length === 0 ? {} : { unavailable }),",
  "    workflow: 'Call a match on its machine: (await machines.get(item.machine.id)).tools[item.path](args). Matches on the current machine can also use tools[item.path](args).'",
  "  };",
  "};"
]

/// The sandbox globals as TypeScript signatures, shown to the model in the
/// `execute` tool description. Keep in step with the prelude above.
export const codevisorSandboxSignatures = `declare const tools: {
  search(input: { query: string; limit?: number; machines?: "all" }): Promise<{ items: Array<{ path: string; name: string; description?: string; machine?: { id: string; name: string } }>; total: number }>
  describe: { tool(input: { path: string }): Promise<Tool> }
  [server: string]: { [tool: string]: (args?: object) => Promise<any> } // tools[path](args) or tools.server.tool(args)
}
declare function status(text: string): void // live progress label shown to the user; call before slow steps
declare const machines: {
  current: Machine // current.tools === tools
  list(): Promise<Machine[]>
  get(idOrName: string): Promise<Machine> // id, exact name, or unique prefix; throws if none or ambiguous
}
interface Machine { id: string; name: string; os?: string; online: boolean; lastSeen?: string; isCurrent: boolean; tools: typeof tools; clients: { list(): Promise<Client[]> } }
declare const clients: { list(): Promise<Client[]> } // Codevisor app windows attached to this machine
interface Client {
  id: string; name: string; platform: "macos" | "ios"; machine: { id: string; name: string }
  online?: boolean; isActive?: boolean; lastActiveAt?: string; isOrigin: boolean // isOrigin: the window that sent this prompt; false for every client when an automation or another agent sent it
  viewing?: { workspaceId?: string; sessionId?: string; page?: string }
  context(): Promise<object>; navigate(args: object): Promise<object>; openPage(args: object): Promise<object>; layout(args: object): Promise<object>; window(args: object): Promise<object>
}
declare class MachineUnavailableError extends Error { machineId: string; machineName?: string; lastSeen?: string; phase: "before-send" | "in-flight" } // in-flight: the call may or may not have completed; never retried automatically
declare class ClientUnavailableError extends Error { clientId: string; clientName?: string; phase: "before-send" | "in-flight" }`
