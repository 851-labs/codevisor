import type { CloudMachinePresence, Project } from "@codevisor/api"
import {
  makeFakeEphemeralProvider,
  SIGN_IN_MARKER,
  type ExecRequest,
  type ExecResult,
  type FakeEphemeralProvider
} from "@codevisor/ephemeral-machines"

import { makeServices } from "../test-support.js"
import { pushRemainingAgents } from "./ephemeral-agents.js"
import { makeEphemeralMachines, type EphemeralMachineDeps } from "./ephemeral-machines.js"
import { makeEphemeralRecordStore } from "./ephemeral-store.js"
import { pushOneWaySync } from "./ephemeral-sync.js"

export const OWNER = "device-owner"
export const JOINED_DEVICE = "device-ephemeral"
export const JOINED_SERVER = "server-ephemeral"

export interface RemoteWorkspace {
  readonly id: string
  isArchived: boolean
}

export interface HarnessControls {
  offline: boolean
  listFails: boolean
  createFails: boolean
  removeFails: boolean
  answer?: (tool: string) => unknown
}

export interface ToolCall {
  readonly machineId: string
  readonly tool: string
  readonly args: Record<string, unknown>
}

export interface EphemeralHarnessOptions {
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
}

const ok = (stdout = "{}"): ExecResult => ({ exitCode: 0, stdout, stderr: "" })

export const ephemeralHarness = async (options: EphemeralHarnessOptions = {}) => {
  const { services } = await makeServices("server-owner")
  const presences: CloudMachinePresence[] = [presence(OWNER, { serverId: "server-owner" })]
  const removed: string[] = []
  const curls: ExecRequest[] = []
  const toolCalls: ToolCall[] = []
  const workspaces: RemoteWorkspace[] = []
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
  const fake: FakeEphemeralProvider = makeFakeEphemeralProvider({
    onExec,
    ...(options.resumable === true ? { resumable: true } : {}),
    ...(options.boots === true ? { boots: true } : {}),
    ...(options.streams === true ? { streams: true } : {}),
    ...(options.prepares === true ? { prepares: true } : {})
  })
  const provider: FakeEphemeralProvider = {
    ...fake,
    create: (spec, machineOptions, progress) =>
      controls.createFails
        ? Promise.reject(new Error("quota exceeded"))
        : fake.create(spec, machineOptions, progress),
    list: (owner) =>
      controls.listFails ? Promise.reject(new Error("401 from provider")) : fake.list(owner)
  }
  const records = makeEphemeralRecordStore(services.db)
  const project: Project = {
    id: "project-1",
    name: "codevisor",
    origin: "codevisor",
    createdAt: "2026-10-01T00:00:00.000Z",
    locations: [],
    repoUrl: "https://github.com/851-labs/codevisor.git",
    ...options.project
  }
  const deps: EphemeralMachineDeps = {
    records,
    providers: {
      get: () => Promise.resolve(provider),
      configured: () => Promise.resolve(["e2b"])
    },
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
      call: (machineId, tool, args) => {
        if (controls.offline) return Promise.reject(new Error("offline"))
        const record = recordOf(args)
        toolCalls.push({ machineId, tool, args: record })
        return Promise.resolve(controls.answer?.(tool) ?? remoteTool(workspaces, tool, record))
      }
    },
    projects: { get: (id) => Promise.resolve(id === project.id ? project : undefined) },
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
  return {
    services,
    deps,
    provider,
    records,
    presences,
    removed,
    curls,
    toolCalls,
    workspaces,
    logs,
    controls,
    machines: makeEphemeralMachines(deps)
  }
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
  options: EphemeralHarnessOptions,
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
  if (tool === "codevisor.workspaces.upsert") {
    workspaces.push({ id: String(args.workspaceId), isArchived: false })
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
