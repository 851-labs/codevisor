import type { CloudMachinePresence, Project } from "@codevisor/api"
import {
  makeFakeSandboxProvider,
  SIGN_IN_MARKER,
  type ExecRequest,
  type ExecResult,
  type FakeSandboxProvider,
  type SandboxAdapter,
  type SandboxField
} from "@codevisor/sandboxes"
import type { SyncEntryRecord } from "@codevisor/sync"

import { run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { pushRemainingAgents } from "./sandbox-agents.js"
import type { SandboxCatalogDeps } from "./sandbox-catalog.js"
import { makeSandboxAdapters, makeSandboxConnections } from "./sandbox-connections.js"
import { makeSandboxLocalWorkspaces } from "./sandbox-local-workspaces.js"
import type { SandboxManagement } from "./sandbox-manager.js"
import { makeRetainedAccounts } from "./sandbox-retained-accounts.js"
import { makeSandboxSettings } from "./sandbox-settings.js"
import { makeSandboxRecordStore } from "./sandbox-store.js"
import { pushOneWaySync } from "./sandbox-sync.js"
import { makeSandboxes, type SandboxDeps } from "./sandboxes.js"

export const OWNER = "device-owner"
export const JOINED_DEVICE = "device-sandbox"
export const JOINED_SERVER = "server-sandbox"

export interface RemoteWorkspace {
  readonly id: string
  readonly name?: string
  isArchived: boolean
}

export interface HarnessControls {
  offline: boolean
  listFails: boolean
  createFails: boolean
  removeFails: boolean
  answer?: (tool: string) => unknown
  beforeList?: () => Promise<void>
}

export interface ToolCall {
  readonly machineId: string
  readonly tool: string
  readonly args: Record<string, unknown>
  readonly sessionId?: string
}

export interface SandboxHarnessOptions {
  readonly joins?: boolean
  readonly bootstrapExit?: number
  readonly owner?: string | undefined
  readonly onCurl?: (request: ExecRequest) => ExecResult
  readonly project?: Partial<Project>
  readonly joinWithoutServerId?: boolean
  readonly resumable?: boolean
  readonly boots?: boolean
  readonly streams?: boolean
  readonly prepares?: boolean
  readonly extraProfileFields?: ReadonlyArray<SandboxField>
  readonly verify?: SandboxAdapter["verify"]
  readonly availability?: () => Promise<string | undefined>
  readonly runsHere?: boolean
  readonly serverId?: string
  readonly management?: Partial<SandboxManagement>
  readonly sharing?: SharedSandboxWorld
}

export interface SharedSandboxWorld {
  readonly provider: FakeSandboxProvider
  readonly presences: CloudMachinePresence[]
  readonly workspaces: RemoteWorkspace[]
}

export const ok = (stdout = "{}"): ExecResult => ({ exitCode: 0, stdout, stderr: "" })

export const readyHarness =
  (harnessId: string) =>
  (request: ExecRequest): ExecResult =>
    request.script.includes("/v1/harnesses'")
      ? ok(JSON.stringify([{ id: harnessId, readiness: { state: "ready" } }]))
      : ok()

export const sandboxHarness = async (options: SandboxHarnessOptions = {}) => {
  const serverId = options.serverId ?? "server-owner"
  const { services } = await makeServices(serverId)
  const presences: CloudMachinePresence[] = options.sharing?.presences ?? [
    presence(OWNER, { serverId })
  ]
  const removed: string[] = []
  const curls: ExecRequest[] = []
  const toolCalls: ToolCall[] = []
  const workspaces: RemoteWorkspace[] = options.sharing?.workspaces ?? []
  const logs: string[] = []
  const controls: HarnessControls = {
    offline: false,
    listFails: false,
    createFails: false,
    removeFails: false
  }
  let clock = Date.parse("2026-10-23T00:00:00.000Z")
  const onExec = (_id: string, request: ExecRequest): ExecResult => {
    if (request.script.includes("auth login --invite")) {
      return bootstrapRun(options, presences, request.script)
    }
    curls.push(request)
    return options.onCurl?.(request) ?? ok()
  }
  const fake: FakeSandboxProvider = makeFakeSandboxProvider({
    onExec,
    ...(options.resumable === true ? { resumable: true } : {}),
    ...(options.boots === true ? { boots: true } : {}),
    ...(options.streams === true ? { streams: true } : {}),
    ...(options.prepares === true ? { prepares: true } : {})
  })
  const provider: FakeSandboxProvider = options.sharing?.provider ?? {
    ...fake,
    definition: {
      ...fake.definition,
      profileFields: [...fake.definition.profileFields, ...(options.extraProfileFields ?? [])]
    },
    ...(options.availability === undefined ? {} : { availability: options.availability }),
    create: (spec, machineOptions, progress) =>
      controls.createFails
        ? Promise.reject(new Error("quota exceeded"))
        : fake.create(spec, machineOptions, progress),
    list: async (owner) => {
      await controls.beforeList?.()
      if (controls.listFails) throw new Error("401 from provider")
      return fake.list(owner)
    }
  }
  const changes: SyncEntryRecord[][] = []
  const records = makeSandboxRecordStore(services.db, {
    serverId,
    now: () => clock,
    changed: (entries) => changes.push([...entries])
  })
  const settings = makeSandboxSettings(services.db, serverId, () => clock)
  await settings.putAccount(FAKE_ACCOUNT)
  await settings.putProfile(FAKE_PROFILE)
  const adapter: SandboxAdapter = {
    definition: provider.definition,
    connect: () => provider,
    ...(options.verify === undefined ? {} : { verify: options.verify })
  }
  const adapters = makeSandboxAdapters([adapter], () => options.runsHere ?? true)
  const providerAccounts = makeRetainedAccounts(services.db, settings)
  const connections = makeSandboxConnections(adapters, {
    accounts: settings.accounts,
    account: providerAccounts.account
  })
  const project: Project = {
    id: "project-1",
    name: "codevisor",
    origin: "codevisor",
    createdAt: "2026-10-01T00:00:00.000Z",
    locations: [],
    repoUrl: "https://github.com/851-labs/codevisor.git",
    ...options.project
  }
  const events: string[] = []
  const stored = await run(
    services.db.createProject({ folderPath: "/fixture/sandbox", name: "codevisor" })
  )
  const projectLookup = {
    get: (id: string) =>
      Promise.resolve(
        id === project.id || id === stored.id ? { ...project, id: stored.id } : undefined
      )
  }
  const deps: SandboxDeps = {
    records,
    management: {
      held: () => true,
      holder: () => undefined,
      hostLocal: () => false,
      forward: () => Promise.reject(new Error("No other machine")),
      ...options.management
    },
    connections,
    providerAccounts,
    profiles: { get: settings.profile },
    serverId,
    account: {
      ownerDeviceId: () => ("owner" in options ? options.owner : OWNER),
      presences: () => presences,
      invite: (kind) => Promise.resolve(`cvi1.aW52aXRl.${kind}-secret-invite-token`),
      remove: (deviceId) => {
        if (controls.removeFails) return Promise.reject(new Error("cloud unreachable"))
        removed.push(deviceId)
        presences.splice(
          presences.findIndex((entry) => entry.deviceId === deviceId),
          1
        )
        return Promise.resolve()
      }
    },
    remoteTools: {
      call: (machineId, tool, args, sessionId) => {
        if (controls.offline) return Promise.reject(new Error("offline"))
        const record = recordOf(args)
        toolCalls.push({
          machineId,
          tool,
          args: record,
          ...(sessionId === undefined ? {} : { sessionId })
        })
        return Promise.resolve(controls.answer?.(tool) ?? remoteTool(workspaces, tool, record))
      }
    },
    projects: projectLookup,
    localWorkspaces: makeSandboxLocalWorkspaces(services.db, projectLookup, {
      publish: (kind, id) => {
        events.push(`${kind} ${id}`)
        return Promise.resolve()
      }
    }),
    sync: (remote, firstHarness) => pushOneWaySync({ db: services.db }, remote, firstHarness),
    syncDeferred: (remote, firstHarness) =>
      pushRemainingAgents({ db: services.db }, remote, firstHarness, {
        attempts: 3,
        intervalMs: 1,
        sleep: () => Promise.resolve()
      }),
    bootstrap: { installUrl: "https://example.test/install.sh" },
    clock: {
      now: () => clock,
      sleep: (ms) => {
        clock += ms
        return Promise.resolve()
      }
    },
    newId: sequentialIds(),
    log: (line) => logs.push(line)
  }
  const machines = makeSandboxes(deps)
  const catalog: SandboxCatalogDeps = {
    settings,
    adapters,
    connections,
    serverId,
    sandboxesUsing: async (accountId) =>
      (await records.list()).filter((record) => record.accountId === accountId).length,
    retireSandboxes: machines.retireProvider,
    newId: sequentialIds(),
    now: () => clock
  }
  return {
    services,
    storedProjectId: stored.id,
    deps,
    catalog,
    settings,
    events,
    provider,
    records,
    changes,
    presences,
    removed,
    curls,
    toolCalls,
    workspaces,
    logs,
    controls,
    machines
  }
}

export const FAKE_ACCOUNT = {
  id: "account-1",
  provider: "e2b" as const,
  label: "Team",
  values: { apiKey: "e2b_secret" },
  createdAt: "2026-10-01T00:00:00.000Z"
}

export const FAKE_PROFILE = {
  id: "profile-1",
  name: "Ubuntu Sandbox",
  provider: "e2b" as const,
  accountId: "account-1",
  values: { size: "small" },
  createdAt: "2026-10-01T00:00:00.000Z"
}

export const presence = (
  deviceId: string,
  extra: Partial<CloudMachinePresence> = {}
): CloudMachinePresence => ({
  deviceId,
  name: deviceId,
  publicKey: "pk",
  online: true,
  lastSeenAt: "2026-10-23T00:00:00.000Z",
  ...extra
})

const bootstrapRun = (
  options: SandboxHarnessOptions,
  presences: CloudMachinePresence[],
  script: string
): ExecResult => {
  const exitCode = options.bootstrapExit ?? 0
  if (exitCode !== 0) return { exitCode, stdout: "", stderr: "install failed\n" }
  if (options.joins === false) return ok("installed")

  const joined = presences.filter((entry) => entry.deviceId.startsWith(JOINED_DEVICE)).length
  const suffix = joined === 0 ? "" : `-${joined + 1}`
  presences.push(
    presence(`${JOINED_DEVICE}${suffix}`, {
      name: /--name '([^']*)'/.exec(script)?.[1] ?? "",
      ...(options.joinWithoutServerId === true ? {} : { serverId: `${JOINED_SERVER}${suffix}` }),
      addedBy: { deviceId: OWNER, name: "owner" },
      ephemeral: { provider: "e2b", ownerDeviceId: OWNER }
    })
  )
  return ok(`installed\n${SIGN_IN_MARKER}\njoined\n`)
}

const remoteTool = (
  workspaces: RemoteWorkspace[],
  tool: string,
  args: Record<string, unknown>
): unknown => {
  if (tool === "codevisor.projects.clone") return { id: "remote-project" }
  if (tool === "codevisor.projects.create_scratch") return { id: "remote-scratch" }
  if (tool === "codevisor.agents.start")
    return { agentId: "remote-agent", workspaceId: "REMOTE-WS" }
  if (tool === "codevisor.workspaces.upsert") {
    workspaces.push({ id: String(args.workspaceId), name: String(args.name), isArchived: false })
    return { id: args.workspaceId }
  }
  return workspaces
}

const recordOf = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? { ...value } : {}

const sequentialIds = (): (() => string) => {
  let next = 0
  return () => {
    next += 1
    return `id-${next}`
  }
}
