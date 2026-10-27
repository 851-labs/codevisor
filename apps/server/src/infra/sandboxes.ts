import type { CloudMachinePresence, CreateSandboxRequest, Sandbox, Project } from "@codevisor/api"
import {
  decodeProviderOptions,
  SANDBOX_PROVIDER_IDS,
  startServerScript,
  type ProviderMachineState,
  type BootstrapRequest,
  type SandboxProvider,
  type SandboxProviderId,
  type ProvisionPlan
} from "@codevisor/sandboxes"

import { HttpFailure } from "../server-context.js"
import { forgetAbandoned, makeAbandonments, type Abandonments } from "./sandbox-abandon.js"
import { joinAccount, requireOwner, teardownMachine } from "./sandbox-account.js"
import { sandboxRemote, type SandboxRemote } from "./sandbox-remote.js"
import {
  makeSandboxSetupProgress,
  type SandboxSetupProgress,
  type SandboxSetupPublisher
} from "./sandbox-setup-log.js"
import type { SandboxRecordStore } from "./sandbox-store.js"
import type { OneWaySyncReport } from "./sandbox-sync.js"
import { isoNow, placeWorkspace, remoteWorkspaceState } from "./sandbox-workspace.js"

export interface SandboxDeps {
  readonly records: SandboxRecordStore
  readonly providers: {
    readonly get: (id: SandboxProviderId) => Promise<SandboxProvider>
    readonly configured: () => Promise<ReadonlyArray<SandboxProviderId>>
  }
  readonly account: {
    readonly ownerDeviceId: () => string | undefined
    readonly presences: () => ReadonlyArray<CloudMachinePresence>
    readonly invite: (provider: SandboxProviderId) => Promise<string>
    readonly remove: (deviceId: string) => Promise<void>
  }
  readonly remoteTools: {
    readonly call: (machineId: string, tool: string, args: unknown) => Promise<unknown>
  }
  readonly projects: { readonly get: (projectId: string) => Promise<Project | undefined> }
  readonly sync: (remote: SandboxRemote, firstHarness?: string) => Promise<OneWaySyncReport>
  readonly syncDeferred: (remote: SandboxRemote, firstHarness: string) => Promise<void>
  readonly bootstrap: Omit<BootstrapRequest, "inviteCode" | "machineName">
  readonly clock: { readonly now: () => number; readonly sleep: (ms: number) => Promise<void> }
  readonly newId: () => string
  readonly log: (line: string) => void
}

export interface Sandboxes {
  readonly list: () => Promise<ReadonlyArray<Sandbox>>
  readonly create: (
    request: CreateSandboxRequest,
    publish?: SandboxSetupPublisher
  ) => Promise<Sandbox>
  readonly destroy: (id: string) => Promise<void>
  readonly claimWorkspace: (id: string, workspaceId: string) => Promise<Sandbox>
  readonly watch: () => Promise<void>
  readonly sweep: () => Promise<void>
  readonly settled: () => Promise<void>
  readonly configuredProviders: () => Promise<ReadonlyArray<SandboxProviderId>>
}

const unopenedWorkspaceGraceMs = 60 * 60 * 1000

const inProgress: ReadonlySet<Sandbox["state"]> = new Set([
  "creating",
  "bootstrapping",
  "syncing",
  "cloning"
])

export const makeSandboxes = (deps: SandboxDeps): Sandboxes => {
  const pipelines = new Set<Promise<void>>()
  const busy = new Set<string>()
  const abandonments = makeAbandonments()

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
    if (machine === undefined) throw new HttpFailure(404, `No sandbox ${id}`)
    if (busy.has(id)) {
      abandonWhileSettingUp(abandonments, machine)
      return
    }

    await exclusively(id, () => teardownRecord(deps, machine))
  }

  const create = async (
    request: CreateSandboxRequest,
    publish?: SandboxSetupPublisher
  ): Promise<Sandbox> => {
    requireOwner(deps)
    const provider = await deps.providers.get(request.provider)
    const overrides = await mergedOptions(deps, request)
    const options = asBadRequest(() => decodeProviderOptions(provider, overrides))
    const plan = await planFor(provider, options)
    const machine = newRecord(deps, request, provider, plan)
    if ((await deps.records.get(machine.id)) !== undefined) {
      throw new HttpFailure(409, `A sandbox ${machine.id} already exists`)
    }
    await deps.records.put(machine)
    const planned = { options, plan, abandonments, ...harnessOf(request) }
    track(
      pipelines,
      exclusively(machine.id, async () => {
        const remote = await runPipeline(deps, provider, machine, planned, publish)
        if (remote !== undefined && planned.harnessId !== undefined)
          track(pipelines, installRemainingAgents(deps, remote, planned.harnessId))
      })
    )
    return machine
  }

  return {
    list: deps.records.list,
    create,
    destroy,
    claimWorkspace: (id, workspaceId) => claimWorkspace(deps, id, workspaceId),
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
          deps.log(`Sandbox sweep of ${providerId} failed: ${messageOf(cause)}`)
        )
      }
    },
    configuredProviders: deps.providers.configured,
    settled: async () => {
      while (pipelines.size > 0) await Promise.all(pipelines)
    }
  }
}

interface PlannedProvision {
  readonly options: unknown
  readonly plan: ProvisionPlan
  readonly abandonments: Abandonments
  readonly harnessId?: string
}

const runPipeline = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  initial: Sandbox,
  planned: PlannedProvision,
  publish: SandboxSetupPublisher | undefined
): Promise<SandboxRemote | undefined> => {
  const record = recordWriter(deps, initial)
  const setup = makeSandboxSetupProgress({
    machineId: initial.id,
    now: () => isoNow(deps),
    publish,
    persist: (steps) => {
      record.advance({ steps }).catch(() => undefined)
    }
  })
  const remote = await provisionOrFail(deps, provider, record, setup, planned)
  if (!planned.abandonments.settle(initial.id)) return remote

  await forgetAbandoned(deps, record.current())
  return undefined
}

const provisionOrFail = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  record: RecordWriter,
  setup: SandboxSetupProgress,
  planned: PlannedProvision
): Promise<SandboxRemote | undefined> => {
  try {
    return await provision(deps, provider, record, setup, planned)
  } catch (cause) {
    await teardownMachine(deps, provider, record.current()).catch(() => undefined)
    await record.advance({ state: "failed", error: messageOf(cause) })
    return undefined
  }
}

const provision = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  record: RecordWriter,
  setup: SandboxSetupProgress,
  planned: PlannedProvision
): Promise<SandboxRemote> => {
  const checkpoint = () => planned.abandonments.checkpoint(initialId(record))
  const options = await prepared(provider, planned, setup)
  checkpoint()
  setup.stage("create")
  setup.log(`Creating a ${provider.displayName} machine`)
  const { preinstalled = false, ...created } = await provider.create(
    specFor(deps, record.current()),
    options,
    setup
  )
  await record.advance({ ...created, state: "bootstrapping" })
  checkpoint()
  if (!preinstalled) setup.stage("install")
  const joined = await joinAccount(
    deps,
    provider,
    { ...record.current(), ...created },
    { setup, preinstalled }
  )
  await record.advance({ ...joined, state: "syncing" })
  checkpoint()
  setup.stage("sync")
  const remote = sandboxRemote(provider, created.providerMachineId)
  const report = await deps.sync(remote, planned.harnessId)
  setup.log(`Pushed ${report.entries} settings`)
  deps.log(`Sandbox ${initialId(record)}: pushed ${report.entries} sync entries one way`)
  await record.advance({ state: "cloning" })
  checkpoint()
  setup.stage("clone")
  const placed = await placeWorkspace(deps, { ...record.current(), ...joined }, setup.log)
  setup.finish()
  await record.advance({ ...placed, state: "ready" })
  return remote
}

const installRemainingAgents = async (
  deps: SandboxDeps,
  remote: SandboxRemote,
  firstHarness: string
): Promise<void> => {
  await deps.syncDeferred(remote, firstHarness).catch((cause: unknown) => {
    deps.log(`Installing the remaining agents failed: ${messageOf(cause)}`)
  })
}

const claimWorkspace = async (
  deps: SandboxDeps,
  id: string,
  workspaceId: string
): Promise<Sandbox> => {
  const machine = await deps.records.get(id)
  if (machine === undefined) throw new HttpFailure(404, `No sandbox ${id}`)
  const wanted = workspaceId.toLowerCase()
  if (machine.workspaceId === wanted) return machine
  if (machine.state !== "ready" || machine.workspaceId !== undefined)
    throw new HttpFailure(409, `${machine.name} can't move to another workspace`)

  const claimed = { ...machine, workspaceId: wanted }
  await deps.records.put(claimed)
  return claimed
}

const abandonWhileSettingUp = (abandonments: Abandonments, machine: Sandbox): void => {
  if (!inProgress.has(machine.state))
    throw new HttpFailure(409, `${machine.name} is still being set up or torn down`)

  abandonments.abandon(machine.id)
}

const harnessOf = (request: CreateSandboxRequest): { readonly harnessId?: string } =>
  request.harnessId === undefined ? {} : { harnessId: request.harnessId }

const planFor = async (provider: SandboxProvider, options: unknown): Promise<ProvisionPlan> =>
  (await provider.plan?.(options)) ?? { stages: provider.provisionStages, preinstalled: false }

const prepared = async (
  provider: SandboxProvider,
  planned: PlannedProvision,
  setup: SandboxSetupProgress
): Promise<unknown> => {
  if (provider.prepare === undefined) return planned.options
  return provider.prepare(planned.options, planned.plan, setup)
}

interface RecordWriter {
  readonly current: () => Sandbox
  readonly advance: (patch: Partial<Sandbox>) => Promise<void>
}

const recordWriter = (deps: SandboxDeps, initial: Sandbox): RecordWriter => {
  let machine = initial
  let written: Promise<void> = Promise.resolve()
  return {
    current: () => machine,
    advance: (patch) => {
      machine = { ...machine, ...patch }
      const snapshot = machine
      written = written.catch(() => undefined).then(() => deps.records.put(snapshot))
      return written
    }
  }
}

const initialId = (record: RecordWriter): string => record.current().id

type PlacedMachine = Sandbox & {
  readonly providerMachineId: string
  readonly machineId: string
}

const isPlaced = (machine: Sandbox): machine is PlacedMachine =>
  machine.state === "ready" &&
  machine.providerMachineId !== undefined &&
  machine.machineId !== undefined

const watchOne = async (deps: SandboxDeps, machine: PlacedMachine): Promise<void> => {
  const provider = await deps.providers.get(machine.provider)
  const { state } = await provider.status(machine.providerMachineId)
  if (state === "stopped" && provider.resume !== undefined) {
    await resumeMachine(deps, provider, machine)
    return
  }
  const reason = await endedReason(deps, machine, state)
  if (reason === undefined) return

  deps.log(`Destroying sandbox ${machine.name} (${machine.id}): ${reason}`)
  await teardownRecord(deps, machine)
}

const resumeMachine = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Resuming sandbox ${machine.name} (${machine.id})`)
  await provider.resume?.(machine.providerMachineId)
  await provider.exec(machine.providerMachineId, {
    script: startServerScript(deps.bootstrap.serverEnvironment)
  })
}

const endedReason = async (
  deps: SandboxDeps,
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

const noteWorkspaceOpened = async (deps: SandboxDeps, machine: PlacedMachine): Promise<void> => {
  if (machine.workspaceOpenedAt !== undefined) return

  await deps.records.put({ ...machine, workspaceOpenedAt: isoNow(deps) })
}

const missingWorkspaceReason = (deps: SandboxDeps, machine: PlacedMachine): string | undefined => {
  if (machine.workspaceOpenedAt !== undefined) return "its workspace is gone"
  if (deps.clock.now() - Date.parse(machine.createdAt) < unopenedWorkspaceGraceMs) return undefined
  return "nobody opened its workspace"
}

const teardownRecord = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  await deps.records.put({ ...machine, state: "destroying" })
  await teardownMachine(deps, await deps.providers.get(machine.provider), machine)
  await deps.records.remove(machine.id)
}

const failInterrupted = async (deps: SandboxDeps, busy: ReadonlySet<string>): Promise<void> => {
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
  deps: SandboxDeps,
  owner: string,
  providerId: SandboxProviderId
): Promise<void> => {
  const provider = await deps.providers.get(providerId)
  const live = new Set((await deps.records.list()).filter(isLive).map((machine) => machine.id))
  for (const orphan of await provider.list(owner)) {
    if (live.has(orphan.tags.machine)) continue
    deps.log(`Destroying orphaned ${provider.displayName} machine ${orphan.providerMachineId}`)
    await provider.destroy(orphan.providerMachineId)
  }
}

const isLive = (machine: Sandbox): boolean => machine.state !== "failed"

const mergedOptions = async (
  deps: SandboxDeps,
  request: CreateSandboxRequest
): Promise<Record<string, unknown>> => ({
  ...(await deps.records.projectOptions(request.projectId))[request.provider],
  ...request.options
})

const newRecord = (
  deps: SandboxDeps,
  request: CreateSandboxRequest,
  provider: SandboxProvider,
  plan: ProvisionPlan
): Sandbox => {
  const id = request.id?.toLowerCase() ?? deps.newId()
  return {
    id,
    provider: request.provider,
    name: request.name?.trim() || `${provider.displayName} ${id.slice(0, 8)}`,
    projectId: request.projectId,
    state: "creating",
    createdAt: isoNow(deps),
    plan: [
      ...plan.stages,
      ...(plan.preinstalled ? [] : ["install" as const]),
      "signIn",
      "sync",
      "clone"
    ],
    ...(request.workspaceId === undefined
      ? {}
      : { workspaceId: request.workspaceId.toLowerCase() }),
    ...(defersWorkspace(request) ? { defersWorkspace: true } : {})
  }
}

const defersWorkspace = (request: CreateSandboxRequest): boolean =>
  request.defersWorkspace === true && request.workspaceId === undefined

const specFor = (deps: SandboxDeps, machine: Sandbox) => ({
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
  isConfigured: (id: SandboxProviderId) => Promise<boolean>
): Promise<ReadonlyArray<SandboxProviderId>> => {
  const flags = await Promise.all(SANDBOX_PROVIDER_IDS.map(isConfigured))
  return SANDBOX_PROVIDER_IDS.filter((_, index) => flags[index] === true)
}
