import {
  decode,
  FLEET_CALLER_HEADER,
  SessionSummary,
  StartedAgent,
  Workspace,
  type MachineCallOrigin
} from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"
import { Schema } from "effect"

import { makeFleetTickets, withTicket, type FleetTickets } from "../infra/fleet-tickets.js"
import type { MachineLink } from "../infra/machine-link.js"
import type { CodevisorServerServices } from "../server-context.js"
import {
  defaultServerConfig,
  startCodevisorServer,
  type RunningCodevisorServer
} from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"
import { isRecord } from "../unknown-values.js"
import { createBot, decodeBot, setUpWith } from "./bot-test-support.js"

export interface Member {
  readonly id: string
  readonly name: string
  readonly publicKey: string
}

export const studio: Member = { id: "machine-studio", name: "Studio", publicKey: "studio-key" }
export const laptop: Member = { id: "machine-laptop", name: "Laptop", publicKey: "laptop-key" }
export const stranger: Member = {
  id: "machine-stranger",
  name: "Stranger",
  publicKey: "stranger-key"
}

export interface FleetMachine {
  readonly agents: Awaited<ReturnType<typeof makeServices>>["agents"]
  readonly server: RunningCodevisorServer
  readonly services: Awaited<ReturnType<typeof makeServices>>["services"] &
    Pick<CodevisorServerServices, "machines" | "fleetTickets">
  readonly fleetTickets: FleetTickets
  readonly machines: MachineLink
}

export interface Answer {
  readonly status: number
  readonly body: unknown
}

interface Fleet {
  readonly machines: Map<string, FleetMachine>
  readonly offline: Set<string>
}

export const createArgs = {
  projectId: "laptop-project",
  harnessId: "codex",
  title: "Fix the laptop"
}

export const startFleet = async () => {
  const fleet: Fleet = { machines: new Map(), offline: new Set() }
  const home = await setUpWith(() => startMachine(studio, fleet))
  await home.addProject("bot-project", "bot-repo")
  const remote = await setUpWith(() => startMachine(laptop, fleet))
  await remote.addProject("laptop-project", "laptop-repo")
  const bot = decodeBot(
    (await createBot(home, { projectIds: ["bot-project"], conversational: true })).body
  )
  const botOrigin: MachineCallOrigin = {
    machineId: studio.id,
    machineName: studio.name,
    sessionId: bot.sessionId,
    botId: bot.id
  }
  const setOffline = (machineId: string, offline: boolean) => {
    if (offline) fleet.offline.add(machineId)
    else fleet.offline.delete(machineId)
  }
  return { home, remote, bot, botOrigin, setOffline }
}

export const postInvoke = async (
  url: string,
  body: unknown,
  headers: Record<string, string> = {}
): Promise<Answer> => {
  const response = await fetch(`${url}/v1/gateway/invoke`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body)
  })
  return { status: response.status, body: (await response.json()) as unknown }
}

export const invokeAs = (caller: Member, target: FleetMachine, body: unknown): Promise<Answer> =>
  withTicket(
    target.fleetTickets.callers,
    { deviceId: caller.id, publicKey: caller.publicKey },
    (ticket) => postInvoke(target.server.url, body, { [FLEET_CALLER_HEADER]: ticket })
  )

export const resultOf = (body: unknown): unknown => (isRecord(body) ? body.result : undefined)

export const startArgs = (prompt: string) => ({
  project: "laptop-project",
  harness: "codex",
  title: "Fix the laptop",
  isolation: "project",
  prompt
})

export const startedSession = async (
  machine: FleetMachine,
  result: unknown
): Promise<SessionSummary> => {
  const { agentId } = decode(StartedAgent)(result)
  const detail = (await jsonRequest(machine.server, `/v1/sessions/${agentId}`)).body
  return decode(Schema.Struct({ session: SessionSummary }))(detail).session
}

export const workspaceOf = async (machine: FleetMachine, session: SessionSummary) =>
  decode(Schema.Array(Workspace))((await jsonRequest(machine.server, "/v1/workspaces")).body).find(
    (workspace) => workspace.id === session.workspaceId
  )

export const post = (machine: FleetMachine, path: string, body: unknown, method = "POST") =>
  jsonRequest(machine.server, path, { method, body: JSON.stringify(body) })

const startMachine = async (self: Member, fleet: Fleet): Promise<FleetMachine> => {
  const made = await makeServices(self.id)
  const fleetTickets = makeFleetTickets()
  const machines: MachineLink = {
    list: async () => [{ id: self.id, name: self.name, online: true, isCurrent: true }],
    resolve: () => undefined,
    machineIdOf: (caller) =>
      [studio, laptop].find(
        (member) =>
          member.id !== self.id &&
          member.id === caller.deviceId &&
          member.publicKey === caller.publicKey
      )?.id,
    invoke: (machine, path, args, origin) => {
      if (fleet.offline.has(machine)) return Promise.reject(offlineError(machine))
      return callAs(self, fleet.machines.get(machine)!, { path, args: args ?? null, origin })
    }
  }
  const services = { ...made.services, machines, fleetTickets }
  const server = await run(
    startCodevisorServer(
      services,
      defaultServerConfig({ bootId: "test-boot", id: self.id, port: 0 })
    )
  )
  runningServers.push(server)
  const machine = { agents: made.agents, server, services, fleetTickets, machines }
  fleet.machines.set(self.id, machine)
  return machine
}

const offlineError = (machine: string): CodeExecutionToolError =>
  new CodeExecutionToolError(`${machine} is offline`, {
    code: "machine_unavailable",
    details: { machineId: machine, phase: "before-send" }
  })

const callAs = async (caller: Member, target: FleetMachine, body: unknown): Promise<unknown> => {
  const answer = await invokeAs(caller, target, body)
  if (answer.status !== 200) throw new Error(JSON.stringify(answer.body))
  return resultOf(answer.body)
}
