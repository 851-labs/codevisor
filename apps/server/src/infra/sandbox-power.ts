import type { Sandbox } from "@codevisor/api"
import {
  pauseAfterMs,
  readProfileOptions,
  startServerScript,
  type SandboxFieldValues,
  type SandboxPausing,
  type SandboxProvider
} from "@codevisor/sandboxes"

import { requireOwner } from "./sandbox-account.js"
import { connectionOf } from "./sandbox-profile-record.js"
import type { PlacedMachine } from "./sandbox-watch.js"
import { isoNow } from "./sandbox-workspace.js"
import type { SandboxDeps } from "./sandboxes.js"

export interface SandboxPowerState {
  readonly activity: Map<string, number>
  readonly wakeRequests: Set<string>
}

interface ListedAgent {
  readonly state: unknown
  readonly updatedAt: string | undefined
}

interface NotedActivity {
  readonly machine: PlacedMachine
  readonly lastActive: number
}

export interface PowerPlan {
  readonly pausing: SandboxPausing
  readonly pauseAfterMs: number | undefined
  readonly options: SandboxFieldValues
}

export const makeSandboxPowerState = (): SandboxPowerState => ({
  activity: new Map(),
  wakeRequests: new Set()
})

export const powerPlanFor = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  machine: Sandbox
): Promise<PowerPlan | undefined> => {
  const { pausing } = provider
  if (pausing === undefined) return undefined

  const options = await profileOptions(deps, provider, machine)
  return { pausing, pauseAfterMs: pauseAfterMs(options), options }
}

export const tendRunning = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine,
  power: SandboxPowerState
): Promise<void> => {
  const noted = await noteActivity(deps, machine, power)
  if (idleTooLong(deps, plan, noted.lastActive)) {
    await pauseMachine(deps, plan, noted.machine)
    return
  }
  if (needsCycle(deps, plan, noted.machine)) {
    await cycleMachine(deps, plan, noted.machine)
    return
  }

  await keepAlive(deps, plan, noted)
}

export const settleStopped = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine,
  power: SandboxPowerState
): Promise<void> => {
  if (idleTooLong(deps, plan, lastActiveOf(machine, power))) {
    deps.log(`Sandbox ${machine.name} (${machine.id}) was paused by its provider`)
    await deps.records.put({ ...machine, power: "paused" })
    return
  }

  await wakeMachine(deps, plan, machine)
}

export const wakeMachine = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Waking sandbox ${machine.name} (${machine.id})`)
  await deps.records.put({ ...machine, power: "waking" })
  try {
    const awake = await woken(deps, plan, machine)
    await deps.records.put({ ...awake, power: "waking" })
    await waitUntilOnline(deps, machine)
    await deps.records.put({ ...awake, lastActiveAt: isoNow(deps) })
  } catch (cause) {
    deps.log(`Waking sandbox ${machine.name} failed: ${messageOf(cause)}`)
    await deps.records.put({ ...machine, power: "paused" })
  }
}

const pauseMachine = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Pausing sandbox ${machine.name} (${machine.id}): no chat ran on it for a while`)
  const paused = await plan.pausing.pause(machine.providerMachineId)
  const { expiresAt: _expired, ...rest } = machine
  await deps.records.put({
    ...rest,
    power: "paused",
    ...(paused.snapshot === undefined ? {} : { pausedSnapshot: paused.snapshot })
  })
}

const cycleMachine = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Restarting sandbox ${machine.name} (${machine.id}) before its provider ends it`)
  const paused = await plan.pausing.pause(machine.providerMachineId)
  const snapshot = paused.snapshot === undefined ? {} : { pausedSnapshot: paused.snapshot }
  await wakeMachine(deps, plan, { ...machine, power: "paused", ...snapshot })
}

const woken = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  machine: PlacedMachine
): Promise<PlacedMachine> => {
  const paused = {
    providerMachineId: machine.providerMachineId,
    ...(machine.pausedSnapshot === undefined ? {} : { snapshot: machine.pausedSnapshot })
  }
  const spec = { name: machine.name, tags: { owner: requireOwner(deps), machine: machine.id } }
  const awake = await plan.pausing.wake(paused, spec, plan.options)
  const provider = await deps.connections.connect(connectionOf(machine))
  await startServer(deps, provider, awake.providerMachineId).catch(async (cause: unknown) => {
    if (awake.providerMachineId !== machine.providerMachineId) {
      await provider.destroy(awake.providerMachineId).catch(() => undefined)
    }
    throw cause
  })
  return runningRecord(deps, machine, awake)
}

const waitUntilOnline = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  const deadline = deps.clock.now() + onlineTimeoutMs
  while (deps.clock.now() < deadline) {
    if (isOnline(deps, machine.deviceId)) return
    await deps.clock.sleep(onlinePollMs)
  }
  deps.log(`Sandbox ${machine.name} (${machine.id}) woke but hasn't come back online yet`)
}

const isOnline = (deps: SandboxDeps, deviceId: string | undefined): boolean =>
  deps.account.presences().some((presence) => presence.deviceId === deviceId && presence.online)

const startServer = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  providerMachineId: string
): Promise<void> => {
  const started = await provider.exec(providerMachineId, {
    script: startServerScript(deps.bootstrap.serverEnvironment)
  })
  if (started.exitCode !== 0) throw new Error(`Codevisor didn't start: ${started.stderr.trim()}`)
}

const runningRecord = (
  deps: SandboxDeps,
  machine: PlacedMachine,
  awake: { readonly providerMachineId: string; readonly expiresAt?: string }
): PlacedMachine => {
  const { power: _power, pausedSnapshot: _snapshot, expiresAt: _expired, ...rest } = machine
  return {
    ...rest,
    providerMachineId: awake.providerMachineId,
    lastActiveAt: isoNow(deps),
    ...(awake.expiresAt === undefined ? {} : { expiresAt: awake.expiresAt })
  }
}

const keepAlive = async (
  deps: SandboxDeps,
  plan: PowerPlan,
  { machine, lastActive }: NotedActivity
): Promise<void> => {
  const until = keepAliveUntil(deps, plan, lastActive)
  if (plan.pausing.keepAlive === undefined || !expiresBefore(deps, machine, until)) return

  const expiresAt = await plan.pausing.keepAlive(machine.providerMachineId, until)
  if (expiresAt === undefined || expiresAt === machine.expiresAt) return

  await deps.records.put({ ...machine, expiresAt })
}

const noteActivity = async (
  deps: SandboxDeps,
  machine: PlacedMachine,
  power: SandboxPowerState
): Promise<NotedActivity> => {
  const seen = await chatActivity(deps, machine)
  if (seen > (power.activity.get(machine.id) ?? 0)) power.activity.set(machine.id, seen)
  const lastActive = lastActiveOf(machine, power)
  if (!activityIsStale(machine, lastActive)) return { machine, lastActive }

  const noted = { ...machine, lastActiveAt: new Date(lastActive).toISOString() }
  await deps.records.put(noted)
  return { machine: noted, lastActive }
}

const chatActivity = async (deps: SandboxDeps, machine: PlacedMachine): Promise<number> => {
  const listed = await deps.remoteTools
    .call(machine.machineId, "codevisor.agents.list", {})
    .catch(() => undefined)
  const agents = agentsIn(listed)
  if (agents.some((agent) => RUNNING_TURN_STATES.has(agent.state))) return deps.clock.now()
  return Math.max(0, ...agents.map((agent) => timeOf(agent.updatedAt)))
}

const lastActiveOf = (machine: Sandbox, power: SandboxPowerState): number =>
  Math.max(
    power.activity.get(machine.id) ?? 0,
    timeOf(machine.lastActiveAt),
    timeOf(machine.workspaceOpenedAt),
    timeOf(machine.createdAt)
  )

const idleTooLong = (deps: SandboxDeps, plan: PowerPlan, lastActive: number): boolean =>
  plan.pauseAfterMs !== undefined && deps.clock.now() - lastActive >= plan.pauseAfterMs

const needsCycle = (deps: SandboxDeps, plan: PowerPlan, machine: PlacedMachine): boolean =>
  plan.pausing.keepAlive === undefined &&
  machine.expiresAt !== undefined &&
  timeOf(machine.expiresAt) - deps.clock.now() < cycleMarginMs

const keepAliveUntil = (deps: SandboxDeps, plan: PowerPlan, lastActive: number): number => {
  const horizon = deps.clock.now() + keepAliveHorizonMs
  if (plan.pauseAfterMs === undefined) return horizon
  return Math.min(horizon, lastActive + plan.pauseAfterMs + backstopSlackMs)
}

const expiresBefore = (deps: SandboxDeps, machine: PlacedMachine, until: number): boolean => {
  if (machine.expiresAt === undefined) return true
  const expiresAt = timeOf(machine.expiresAt)
  return expiresAt < until && expiresAt - deps.clock.now() < refreshBelowMs
}

const activityIsStale = (machine: Sandbox, lastActive: number): boolean =>
  lastActive - timeOf(machine.lastActiveAt) >= persistActivityEveryMs

const profileOptions = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  machine: Sandbox
): Promise<SandboxFieldValues> => {
  if (machine.profileId === undefined) return readProfileOptions(provider.definition, {})

  const profile = await deps.profiles.get(machine.profileId)
  return readProfileOptions(provider.definition, profile?.values ?? {})
}

const agentsIn = (listed: unknown): ReadonlyArray<ListedAgent> => {
  const items = isRecord(listed) ? listed["items"] : undefined
  if (!Array.isArray(items)) return []
  return items.filter(isRecord).map(listedAgent)
}

const listedAgent = (item: Record<string, unknown>): ListedAgent => {
  const updatedAt = item["updatedAt"]
  return { state: item["state"], updatedAt: typeof updatedAt === "string" ? updatedAt : undefined }
}

const timeOf = (iso: string | undefined): number => {
  const time = iso === undefined ? Number.NaN : Date.parse(iso)
  return Number.isNaN(time) ? 0 : time
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const RUNNING_TURN_STATES: ReadonlySet<unknown> = new Set(["working", "waitingForUser"])
const minuteMs = 60 * 1000
const cycleMarginMs = 30 * minuteMs
const keepAliveHorizonMs = 60 * minuteMs
const refreshBelowMs = 20 * minuteMs
const backstopSlackMs = 5 * minuteMs
const persistActivityEveryMs = 5 * minuteMs
const onlineTimeoutMs = 3 * minuteMs
const onlinePollMs = 2 * 1000
