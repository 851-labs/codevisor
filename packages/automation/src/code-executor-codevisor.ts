import { codevisorToolNames } from "./codevisor-provider.js"
import { codevisorToolScopes } from "./codevisor-tool-scopes.js"

const ownGlobals = new Set(["agents", "machines"])

export const codevisorToolsSource = (): ReadonlyArray<string> => {
  const scopes = codevisorToolScopes(codevisorToolNames())
  return [
    `const __codevisorScopes = ${JSON.stringify(scopes)};`,
    ...callSource,
    ...agentSource,
    ...groupsOf(scopes).map(
      (group) => `const ${group} = __codevisorGroup(${JSON.stringify(group)});`
    )
  ]
}

const groupsOf = (scopes: Readonly<Record<string, unknown>>): ReadonlyArray<string> => [
  ...new Set(
    Object.keys(scopes)
      .map((name) => name.split(".")[0]!)
      .filter((group) => !ownGlobals.has(group))
  )
]

const callSource: ReadonlyArray<string> = [
  "const __scopeNote = (scope) => scope === 'account' ? 'shared by all your machines' : 'about this chat';",
  "const __machineTarget = async (machine) => {",
  "  if (machine === undefined || machine === null) return undefined;",
  "  const info = typeof machine === 'object' && typeof machine.machineId === 'string' ? machine : await machines.get(__stringMatcher(machine, 'machine'));",
  "  if (info.machineId === __currentMachineInfo.machineId) return undefined;",
  "  return { machine: info.machineId, ...(typeof info.name === 'string' ? { machineName: info.name } : {}) };",
  "};",
  "const __machineOf = (target) => target === undefined ? { machineId: __currentMachineInfo.machineId, name: __currentMachineInfo.name } : { machineId: target.machine, name: target.machineName ?? target.machine };",
  "const __codevisorCall = async (tool, args) => {",
  "  const scope = __codevisorScopes[tool];",
  "  if (scope === undefined) throw new Error(tool + ' is not a Codevisor tool. Find tools with machines.current.tools.search({ query })');",
  "  const { machine, ...rest } = args && typeof args === 'object' ? args : {};",
  "  if (scope !== 'machine' && machine !== undefined) throw new Error(tool + ' is ' + __scopeNote(scope) + ', so it takes no machine');",
  "  const target = scope === 'machine' ? await __machineTarget(machine) : undefined;",
  "  return { target, result: await __callTool('codevisor.' + tool, rest, target) };",
  "};",
  "const __codevisorGroup = (group, shape = (_tool, called) => called.result) => {",
  "  const at = (path) => new Proxy(() => undefined, {",
  "    get(_target, prop) { if (prop === 'then' || typeof prop === 'symbol') return undefined; return at([...path, String(prop)]); },",
  "    apply(_target, _thisArg, args) { const tool = path.join('.'); return __codevisorCall(tool, args[0]).then((called) => shape(tool, called)); }",
  "  });",
  "  return at([group]);",
  "};",
  "const machines = new Proxy(__machinesCore, { get(target, prop) { if (prop in target || typeof prop === 'symbol') return target[prop]; return (args) => __codevisorCall('machines.' + String(prop), args).then((called) => called.result); } });"
]

const agentSource: ReadonlyArray<string> = [
  "const __makeAgent = (raw, machine) => {",
  "  const agentId = raw.agentId;",
  "  const on = (args = {}) => ({ ...args, agentId, machine: machine.machineId });",
  "  const debug = new Proxy({}, { get(_target, prop) { if (prop === 'then' || typeof prop === 'symbol') return undefined; return (args = {}) => agents.debug[String(prop)](on(args)); } });",
  "  return __hidden({ ...raw, machine }, {",
  "    message: (args = {}) => agents.message(on(typeof args === 'string' ? { text: args } : args)),",
  "    status: () => agents.status(on()),",
  "    answer: (args = {}) => agents.answer(on(args)),",
  "    cancel: () => agents.cancel(on()),",
  "    wait: (args = {}) => agents.wait({ ...args, agentIds: [agentId], machine: machine.machineId }),",
  "    archive: () => agents.archive({ agentId }),",
  "    debug",
  "  });",
  "};",
  "const __agentResult = (tool, called) => {",
  "  const machine = __machineOf(called.target);",
  "  const result = called.result;",
  "  if (tool === 'agents.start' && result && typeof result.agentId === 'string') return __makeAgent(result, machine);",
  "  if (tool === 'agents.list' && result && Array.isArray(result.items)) return { ...result, items: result.items.map((item) => __makeAgent(item, machine)) };",
  "  return result;",
  "};",
  "const __agentOn = async (agentId, machine) => {",
  "  const target = await __machineTarget(machine);",
  "  const status = await __callTool('codevisor.agents.status', { agentId }, target);",
  "  return __makeAgent({ ...status, agentId }, __machineOf(target));",
  "};",
  "const __findAgent = async (args) => {",
  "  const { agentId, machine } = typeof args === 'string' ? { agentId: args } : args ?? {};",
  "  __stringMatcher(agentId, 'agentId');",
  "  if (machine !== undefined) return __agentOn(agentId, machine);",
  "  const others = (await __listMachines(true)).filter((candidate) => !candidate.isCurrent && candidate.online !== false);",
  "  const found = await Promise.all([machines.current, ...others].map((candidate) => __agentOn(agentId, candidate).catch(() => undefined)));",
  "  const agent = found.find((candidate) => candidate !== undefined);",
  "  if (agent === undefined) throw new Error('No machine has agent ' + agentId);",
  "  return agent;",
  "};",
  "const __agentsCore = __codevisorGroup('agents', __agentResult);",
  "const agents = new Proxy(__agentsCore, { get(target, prop) { return prop === 'get' ? __findAgent : target[prop]; } });"
]
