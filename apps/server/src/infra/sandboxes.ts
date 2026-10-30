import type {
  CloudMachinePresence,
  CreateSandboxRequest,
  Sandbox,
  SandboxSetupLog,
  WaitForSandboxResponse,
  SandboxProfile,
  Project
} from "@codevisor/api"
import {
  readProfileOptions,
  type BootstrapRequest,
  type SandboxFieldValues,
  type SandboxProvider,
  type SandboxProviderId,
  type ProvisionPlan
} from "@codevisor/sandboxes"

import { HttpFailure } from "../server-context.js"
import { forgetAbandoned, makeAbandonments, type Abandonments } from "./sandbox-abandon.js"
import { joinAccount, requireOwner, teardownMachine } from "./sandbox-account.js"
import { startRequestedAgent } from "./sandbox-agent-start.js"
import { placementOf, runsElsewhere } from "./sandbox-catalog.js"
import type { SandboxConnection, SandboxConnections } from "./sandbox-connections.js"
import { makeSandboxLogBook } from "./sandbox-log-book.js"
import {
  createdHere,
  existingSandbox,
  IN_PROGRESS,
  makeSandboxRouting,
  managesHere,
  type SandboxManagement,
  type SandboxRouting
} from "./sandbox-manager.js"
import { adoptPlaceholders } from "./sandbox-placeholder.js"
import { makeSandboxPowerState } from "./sandbox-power.js"
import { connectionOf, profileOrMissing } from "./sandbox-profile-record.js"
import { sandboxRemote, type SandboxRemote } from "./sandbox-remote.js"
import {
  harnessOf,
  newRecord,
  restoredFields,
  restoreRequest,
  retryRequest
} from "./sandbox-requests.js"
import type { RetainedAccounts } from "./sandbox-retained-accounts.js"
import {
  retainProviderAccounts,
  retireMachine,
  retireOrphan,
  usingProvider,
  withDeletedProvider
} from "./sandbox-retire.js"
import {
  makeSandboxSetupProgress,
  type SandboxSetupProgress,
  type SandboxSetupPublisher
} from "./sandbox-setup-log.js"
import type { SandboxRecordStore } from "./sandbox-store.js"
import type { OneWaySyncReport } from "./sandbox-sync.js"
import { waitForSandbox } from "./sandbox-wait.js"
import { makeSandboxWaking } from "./sandbox-wake.js"
import { isPlaced, teardownRecord, watchOne } from "./sandbox-watch.js"
import { isoNow, placeWorkspace } from "./sandbox-workspace.js"

export interface SandboxDeps {
  readonly records: SandboxRecordStore
  readonly management: SandboxManagement
  readonly connections: SandboxConnections
  readonly providerAccounts: RetainedAccounts
  readonly profiles: { readonly get: (id: string) => Promise<SandboxProfile | undefined> }
  readonly serverId: string
  readonly account: {
    readonly ownerDeviceId: () => string | undefined
    readonly presences: () => ReadonlyArray<CloudMachinePresence>
    readonly invite: (provider: SandboxProviderId) => Promise<string>
    readonly remove: (deviceId: string) => Promise<void>
  }
  readonly remoteTools: {
    readonly call: (
      machineId: string,
      tool: string,
      args: unknown,
      sessionId?: string
    ) => Promise<unknown>
  }
  readonly projects: { readonly get: (projectId: string) => Promise<Project | undefined> }
  readonly localWorkspaces: {
    readonly keepArchived: (placeholder: ArchivedWorkspace) => Promise<boolean>
    readonly remove: (workspaceId: string) => Promise<void>
  }
  readonly sync: (remote: SandboxRemote, firstHarness?: string) => Promise<OneWaySyncReport>
  readonly syncDeferred: (remote: SandboxRemote, firstHarness: string) => Promise<void>
  readonly bootstrap: Omit<BootstrapRequest, "inviteCode" | "machineName">
  readonly clock: { readonly now: () => number; readonly sleep: (ms: number) => Promise<void> }
  readonly newId: () => string
  readonly log: (line: string) => void
}

export interface ArchivedWorkspace {
  readonly workspaceId: string
  readonly name: string
  readonly projectId: string
  readonly sandboxId: string
}

export interface Sandboxes extends SandboxRouting {
  readonly list: () => Promise<ReadonlyArray<Sandbox>>
  readonly get: (id: string) => Promise<Sandbox>
  readonly log: (id: string, last?: number) => Promise<ReadonlyArray<SandboxSetupLog>>
  readonly create: (
    request: CreateSandboxRequest,
    publish?: SandboxSetupPublisher
  ) => Promise<Sandbox>
  readonly retry: (id: string, publish?: SandboxSetupPublisher) => Promise<Sandbox>
  readonly wait: (id: string, timeoutMs: number) => Promise<WaitForSandboxResponse>
  readonly restore: (workspaceId: string) => Promise<void>
  readonly retireProvider: (accountId: string) => Promise<void>
  readonly watch: () => Promise<void>
  readonly sweep: () => Promise<void>
  readonly settled: () => Promise<void>
}

export const makeSandboxes = (deps: SandboxDeps): Sandboxes => {
  const pipelines = new Set<Promise<unknown>>()
  const busy = new Set<string>()
  const abandonments = makeAbandonments()
  const logs = makeSandboxLogBook()
  const power = makeSandboxPowerState()

  const exclusively = async (id: string, work: () => Promise<void>): Promise<void> => {
    if (busy.has(id)) return
    busy.add(id)
    try {
      await work()
    } finally {
      busy.delete(id)
    }
  }

  const destroyHere = async (machine: Sandbox): Promise<undefined> => {
    if (busy.has(machine.id)) {
      abandonWhileSettingUp(abandonments, machine)
      return
    }

    await exclusively(machine.id, () => teardownRecord(deps, machine))
  }

  const waking = makeSandboxWaking(deps, power, {
    exclusively,
    track: (pipeline) => track(pipelines, pipeline)
  })
  const routing = makeSandboxRouting(deps, { destroyHere, wakeHere: waking.wakeHere })

  const create = async (
    request: CreateSandboxRequest,
    publish?: SandboxSetupPublisher,
    restoring: Partial<Sandbox> = {}
  ): Promise<Sandbox> => {
    requireOwner(deps)
    const profile = await profileOrMissing(deps, request.profileId)
    const provider = await deps.connections.connect(connectionOf(profile))
    if (runsElsewhere(provider.definition, await placementOf(deps, profile), deps.serverId)) {
      throw new HttpFailure(409, `${profile.name} runs on another Mac`)
    }
    const options = asBadRequest(() => readProfileOptions(provider.definition, profile.values))
    const plan = await planFor(provider, options)
    const machine = { ...newRecord(deps, request, profile, plan), ...restoring }
    if ((await deps.records.get(machine.id)) !== undefined) {
      throw new HttpFailure(409, `A sandbox ${machine.id} already exists`)
    }
    await deps.records.put(machine)
    logs.start(machine.id)
    const planned = { options, plan, abandonments, ...harnessOf(request) }
    const recorded = logs.recording(publish)
    track(
      pipelines,
      exclusively(machine.id, async () => {
        const remote = await runPipeline(deps, provider, machine, planned, recorded)
        if (remote !== undefined && planned.harnessId !== undefined)
          track(pipelines, installRemainingAgents(deps, remote, planned.harnessId))
      })
    )
    return machine
  }

  const retry = async (id: string, publish?: SandboxSetupPublisher): Promise<Sandbox> => {
    const failed = await existingSandbox(deps, id)
    const request = retryRequest(failed)
    await deps.records.remove(id)
    return create(request, publish).catch(async (cause: unknown) => {
      await deps.records.put(failed)
      throw cause
    })
  }

  const retire = async (
    machines: ReadonlyArray<Sandbox>,
    retireOne: (deps: SandboxDeps, machine: Sandbox) => Promise<void>
  ): Promise<void> => {
    for (const machine of machines) {
      if (isSettingUp(busy, machine)) abandonments.abandon(machine.id)
      else if (managesHere(deps, machine))
        await exclusively(machine.id, () => retireOne(deps, machine))
    }
  }

  const restoreArchived = async (workspaceId: string): Promise<void> => {
    const archived = await archivedFor(deps, workspaceId)
    if (archived?.profileId === undefined) return

    await deps.records.remove(archived.id)
    await create(
      restoreRequest(archived, archived.profileId, workspaceId.toLowerCase()),
      undefined,
      restoredFields(archived)
    )
  }

  return {
    list: deps.records.list,
    get: (id) => existingSandbox(deps, id),
    log: async (id, last) => {
      await existingSandbox(deps, id)
      return logs.lines(id, last)
    },
    create,
    retry,
    wait: (id, timeoutMs) => waitForSandbox(deps, id, timeoutMs),
    ...routing,
    restore: (workspaceId) => {
      const restoring = restoreArchived(workspaceId)
      track(pipelines, Promise.allSettled([restoring]))
      return restoring
    },
    retireProvider: async (accountId) => {
      await retainProviderAccounts(deps)
      await retire(await usingProvider(deps, accountId), retireMachine)
    },
    watch: async () => {
      await retainProviderAccounts(deps)
      await adoptPlaceholders(deps)
      await retire(await withDeletedProvider(deps), retireOrphan)
      for (const machine of (await deps.records.list()).filter(isPlaced)) {
        if (!managesHere(deps, machine)) continue
        await exclusively(machine.id, async () => {
          await watchOne(deps, machine, power)
          await waking.wakeIfRequested(machine.id)
        })
      }
    },
    sweep: async () => {
      const owner = deps.account.ownerDeviceId()
      if (owner === undefined) return

      await failInterrupted(deps, busy)
      for (const connection of await deps.connections.all()) {
        await sweepConnection(deps, owner, connection).catch((cause: unknown) =>
          deps.log(`Sandbox sweep of ${connection.provider} failed: ${messageOf(cause)}`)
        )
      }
    },
    settled: async () => {
      while (pipelines.size > 0) await Promise.all(pipelines)
    }
  }
}

interface PlannedProvision {
  readonly options: SandboxFieldValues
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
  deps.log(`Sandbox ${initialId(record)}: pushed ${report.entries} sync entries one way`)
  await record.advance({ state: "cloning" })
  checkpoint()
  setup.stage("clone")
  const placed = await placeWorkspace(deps, { ...record.current(), ...joined })
  checkpoint()
  const started = await startRequestedAgent(
    deps,
    remote,
    { ...record.current(), ...joined },
    placed,
    setup
  )
  setup.finish()
  await record.advance({ ...placed, ...started, state: "ready" })
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

const abandonWhileSettingUp = (abandonments: Abandonments, machine: Sandbox): void => {
  if (!IN_PROGRESS.has(machine.state))
    throw new HttpFailure(409, `${machine.name} is still being set up or torn down`)

  abandonments.abandon(machine.id)
}

const isSettingUp = (busy: ReadonlySet<string>, machine: Sandbox): boolean =>
  busy.has(machine.id) && IN_PROGRESS.has(machine.state)

const planFor = async (
  provider: SandboxProvider,
  options: SandboxFieldValues
): Promise<ProvisionPlan> =>
  (await provider.plan?.(options)) ?? { stages: provider.provisionStages, preinstalled: false }

const prepared = async (
  provider: SandboxProvider,
  planned: PlannedProvision,
  setup: SandboxSetupProgress
): Promise<SandboxFieldValues> => {
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

const failInterrupted = async (deps: SandboxDeps, busy: ReadonlySet<string>): Promise<void> => {
  for (const machine of await deps.records.list()) {
    if (!IN_PROGRESS.has(machine.state) || busy.has(machine.id) || !createdHere(deps, machine))
      continue
    const provider = await deps.connections.connect(connectionOf(machine))
    await teardownMachine(deps, provider, machine).catch(() => undefined)
    await deps.records.put({
      ...machine,
      state: "failed",
      error: "Interrupted by a server restart"
    })
  }
}

const sweepConnection = async (
  deps: SandboxDeps,
  owner: string,
  connection: SandboxConnection
): Promise<void> => {
  const provider = await deps.connections.connect(connection)
  const listed = await provider.list(owner)
  const live = await liveIds(deps)
  for (const orphan of listed) {
    if (live.has(orphan.tags.machine)) continue
    deps.log(
      `Destroying orphaned ${provider.definition.displayName} sandbox ${orphan.providerMachineId}`
    )
    await provider.destroy(orphan.providerMachineId)
  }
}

const liveIds = async (deps: SandboxDeps): Promise<ReadonlySet<string>> =>
  new Set((await deps.records.list()).filter(isLive).map((machine) => machine.id))

const isLive = (machine: Sandbox): boolean =>
  machine.state !== "failed" && machine.state !== "archived"

const archivedFor = async (deps: SandboxDeps, workspaceId: string): Promise<Sandbox | undefined> =>
  (await deps.records.list()).find(
    (machine) => machine.state === "archived" && machine.workspaceId === workspaceId.toLowerCase()
  )

const specFor = (deps: SandboxDeps, machine: Sandbox) => ({
  name: machine.name,
  tags: { owner: requireOwner(deps), machine: machine.id }
})

const track = (pipelines: Set<Promise<unknown>>, pipeline: Promise<unknown>): void => {
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
