import type {
  CloudMachinePresence,
  CreateEphemeralMachineRequest,
  EphemeralMachine,
  Project
} from "@codevisor/api"
import {
  decodeProviderOptions,
  EPHEMERAL_PROVIDER_IDS,
  startServerScript,
  type ProviderMachineState,
  type BootstrapRequest,
  type EphemeralProvider,
  type EphemeralProviderId
} from "@codevisor/ephemeral-machines"

import { HttpFailure } from "../server-context.js"
import { joinAccount, requireOwner, teardownMachine } from "./ephemeral-account.js"
import { ephemeralRemote, type EphemeralRemote } from "./ephemeral-remote.js"
import type { EphemeralRecordStore } from "./ephemeral-store.js"
import type { OneWaySyncReport } from "./ephemeral-sync.js"
import { isoNow, placeWorkspace, remoteWorkspaceState } from "./ephemeral-workspace.js"

export interface EphemeralMachineDeps {
  readonly records: EphemeralRecordStore
  readonly providers: {
    readonly get: (id: EphemeralProviderId) => Promise<EphemeralProvider>
    readonly configured: () => Promise<ReadonlyArray<EphemeralProviderId>>
  }
  readonly account: {
    readonly ownerDeviceId: () => string | undefined
    readonly presences: () => ReadonlyArray<CloudMachinePresence>
    readonly invite: (provider: EphemeralProviderId) => Promise<string>
    readonly remove: (deviceId: string) => Promise<void>
  }
  readonly remoteTools: {
    readonly call: (machineId: string, tool: string, args: unknown) => Promise<unknown>
  }
  readonly projects: { readonly get: (projectId: string) => Promise<Project | undefined> }
  readonly sync: (remote: EphemeralRemote) => Promise<OneWaySyncReport>
  readonly bootstrap: Omit<BootstrapRequest, "inviteCode" | "machineName">
  readonly clock: { readonly now: () => number; readonly sleep: (ms: number) => Promise<void> }
  readonly newId: () => string
  readonly log: (line: string) => void
}

export interface EphemeralMachines {
  readonly list: () => Promise<ReadonlyArray<EphemeralMachine>>
  readonly create: (request: CreateEphemeralMachineRequest) => Promise<EphemeralMachine>
  readonly destroy: (id: string) => Promise<void>
  readonly watch: () => Promise<void>
  readonly sweep: () => Promise<void>
  readonly settled: () => Promise<void>
  readonly configuredProviders: () => Promise<ReadonlyArray<EphemeralProviderId>>
}

const unopenedWorkspaceGraceMs = 60 * 60 * 1000

const inProgress: ReadonlySet<EphemeralMachine["state"]> = new Set([
  "creating",
  "bootstrapping",
  "syncing",
  "cloning"
])

export const makeEphemeralMachines = (deps: EphemeralMachineDeps): EphemeralMachines => {
  const pipelines = new Set<Promise<void>>()
  const busy = new Set<string>()

  const exclusively = async (id: string, work: () => Promise<void>): Promise<void> => {
    if (busy.has(id)) return
    busy.add(id)
    try {
      await work()
    } finally {
      busy.delete(id)
    }
  }

  const destroy = async (id: string): Promise<void> => {
    const machine = await deps.records.get(id)
    if (machine === undefined) throw new HttpFailure(404, `No ephemeral machine ${id}`)
    if (busy.has(id))
      throw new HttpFailure(409, `${machine.name} is still being set up or torn down`)

    await exclusively(id, () => teardownRecord(deps, machine))
  }

  const create = async (request: CreateEphemeralMachineRequest): Promise<EphemeralMachine> => {
    requireOwner(deps)
    const provider = await deps.providers.get(request.provider)
    const overrides = await mergedOptions(deps, request)
    const options = asBadRequest(() => decodeProviderOptions(provider, overrides))
    const machine = newRecord(deps, request, provider)
    await deps.records.put(machine)
    track(
      pipelines,
      exclusively(machine.id, () => runPipeline(deps, provider, machine, options))
    )
    return machine
  }

  return {
    list: deps.records.list,
    create,
    destroy,
    watch: async () => {
      for (const machine of (await deps.records.list()).filter(isPlaced)) {
        await exclusively(machine.id, () => watchOne(deps, machine))
      }
    },
    sweep: async () => {
      const owner = deps.account.ownerDeviceId()
      if (owner === undefined) return

      await failInterrupted(deps, busy)
      for (const providerId of await deps.providers.configured()) {
        await sweepProvider(deps, owner, providerId).catch((cause: unknown) =>
          deps.log(`Ephemeral sweep of ${providerId} failed: ${messageOf(cause)}`)
        )
      }
    },
    configuredProviders: deps.providers.configured,
    settled: async () => {
      await Promise.all(pipelines)
    }
  }
}

const runPipeline = async (
  deps: EphemeralMachineDeps,
  provider: EphemeralProvider,
  initial: EphemeralMachine,
  options: unknown
): Promise<void> => {
  let machine = initial
  const advance = async (patch: Partial<EphemeralMachine>): Promise<void> => {
    machine = { ...machine, ...patch }
    await deps.records.put(machine)
  }
  try {
    const created = await provider.create(specFor(deps, machine), options)
    await advance({ ...created, state: "bootstrapping" })
    const joined = await joinAccount(deps, provider, { ...machine, ...created })
    await advance({ ...joined, state: "syncing" })
    const report = await deps.sync(ephemeralRemote(provider, created.providerMachineId))
    deps.log(`Ephemeral ${machine.id}: pushed ${report.entries} sync entries one way`)
    await advance({ state: "cloning" })
    await advance({ ...(await placeWorkspace(deps, { ...machine, ...joined })), state: "ready" })
  } catch (cause) {
    await teardownMachine(deps, provider, machine).catch(() => undefined)
    await advance({ state: "failed", error: messageOf(cause) })
  }
}

type PlacedMachine = EphemeralMachine & {
  readonly providerMachineId: string
  readonly machineId: string
}

const isPlaced = (machine: EphemeralMachine): machine is PlacedMachine =>
  machine.state === "ready" &&
  machine.providerMachineId !== undefined &&
  machine.machineId !== undefined

const watchOne = async (deps: EphemeralMachineDeps, machine: PlacedMachine): Promise<void> => {
  const provider = await deps.providers.get(machine.provider)
  const { state } = await provider.status(machine.providerMachineId)
  if (state === "stopped" && provider.resume !== undefined) {
    await resumeMachine(deps, provider, machine)
    return
  }
  const reason = await endedReason(deps, machine, state)
  if (reason === undefined) return

  deps.log(`Destroying ephemeral machine ${machine.name} (${machine.id}): ${reason}`)
  await teardownRecord(deps, machine)
}

const resumeMachine = async (
  deps: EphemeralMachineDeps,
  provider: EphemeralProvider,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Resuming ephemeral machine ${machine.name} (${machine.id})`)
  await provider.resume?.(machine.providerMachineId)
  await provider.exec(machine.providerMachineId, {
    script: startServerScript(deps.bootstrap.serverEnvironment)
  })
}

const endedReason = async (
  deps: EphemeralMachineDeps,
  machine: PlacedMachine,
  providerState: ProviderMachineState
): Promise<string | undefined> => {
  if (providerState === "gone" || providerState === "stopped") {
    return `its ${machine.provider} machine ended`
  }
  const state = await remoteWorkspaceState(deps, machine).catch(() => "unreachable" as const)
  if (state === "active") await noteWorkspaceOpened(deps, machine)
  if (state === "archived") return "its workspace was archived"
  if (state === "missing") return missingWorkspaceReason(deps, machine)
  return undefined
}

const noteWorkspaceOpened = async (
  deps: EphemeralMachineDeps,
  machine: PlacedMachine
): Promise<void> => {
  if (machine.workspaceOpenedAt !== undefined) return

  await deps.records.put({ ...machine, workspaceOpenedAt: isoNow(deps) })
}

const missingWorkspaceReason = (
  deps: EphemeralMachineDeps,
  machine: PlacedMachine
): string | undefined => {
  if (machine.workspaceOpenedAt !== undefined) return "its workspace is gone"
  if (deps.clock.now() - Date.parse(machine.createdAt) < unopenedWorkspaceGraceMs) return undefined
  return "nobody opened its workspace"
}

const teardownRecord = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine
): Promise<void> => {
  await deps.records.put({ ...machine, state: "destroying" })
  await teardownMachine(deps, await deps.providers.get(machine.provider), machine)
  await deps.records.remove(machine.id)
}

const failInterrupted = async (
  deps: EphemeralMachineDeps,
  busy: ReadonlySet<string>
): Promise<void> => {
  for (const machine of await deps.records.list()) {
    if (!inProgress.has(machine.state) || busy.has(machine.id)) continue
    const provider = await deps.providers.get(machine.provider)
    await teardownMachine(deps, provider, machine).catch(() => undefined)
    await deps.records.put({
      ...machine,
      state: "failed",
      error: "Interrupted by a server restart"
    })
  }
}

const sweepProvider = async (
  deps: EphemeralMachineDeps,
  owner: string,
  providerId: EphemeralProviderId
): Promise<void> => {
  const provider = await deps.providers.get(providerId)
  const live = new Set((await deps.records.list()).filter(isLive).map((machine) => machine.id))
  for (const orphan of await provider.list(owner)) {
    if (live.has(orphan.tags.machine)) continue
    deps.log(`Destroying orphaned ${provider.displayName} machine ${orphan.providerMachineId}`)
    await provider.destroy(orphan.providerMachineId)
  }
}

const isLive = (machine: EphemeralMachine): boolean => machine.state !== "failed"

const mergedOptions = async (
  deps: EphemeralMachineDeps,
  request: CreateEphemeralMachineRequest
): Promise<Record<string, unknown>> => ({
  ...(await deps.records.projectOptions(request.projectId))[request.provider],
  ...request.options
})

const newRecord = (
  deps: EphemeralMachineDeps,
  request: CreateEphemeralMachineRequest,
  provider: EphemeralProvider
): EphemeralMachine => {
  const id = deps.newId()
  return {
    id,
    provider: request.provider,
    name: request.name?.trim() || `${provider.displayName} ${id.slice(0, 8)}`,
    projectId: request.projectId,
    state: "creating",
    createdAt: isoNow(deps),
    ...(request.workspaceId === undefined ? {} : { workspaceId: request.workspaceId.toLowerCase() })
  }
}

const specFor = (deps: EphemeralMachineDeps, machine: EphemeralMachine) => ({
  name: machine.name,
  tags: { owner: requireOwner(deps), machine: machine.id }
})

const track = (pipelines: Set<Promise<void>>, pipeline: Promise<void>): void => {
  pipelines.add(pipeline)
  void pipeline.finally(() => pipelines.delete(pipeline))
}

export const asBadRequest = <T>(decode: () => T): T => {
  try {
    return decode()
  } catch (cause) {
    throw new HttpFailure(400, messageOf(cause))
  }
}

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const configuredProviderIds = async (
  isConfigured: (id: EphemeralProviderId) => Promise<boolean>
): Promise<ReadonlyArray<EphemeralProviderId>> => {
  const flags = await Promise.all(EPHEMERAL_PROVIDER_IDS.map(isConfigured))
  return EPHEMERAL_PROVIDER_IDS.filter((_, index) => flags[index] === true)
}
