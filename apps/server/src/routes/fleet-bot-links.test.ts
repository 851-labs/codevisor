import {
  BOT_LINK_HEADER,
  decode,
  FLEET_CALLER_HEADER,
  FLEET_SESSION_EVENT_PATH,
  SessionSummary,
  Workspace,
  type MachineCallOrigin
} from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { makeFleetTickets, withTicket } from "../infra/fleet-tickets.js"
import type { MachineLink } from "../infra/machine-link.js"
import {
  defaultServerConfig,
  startCodevisorServer,
  type RunningCodevisorServer
} from "../server.js"
import { jsonRequest, makeServices, run, runningServers, waitFor } from "../test-support.js"
import { isRecord } from "../unknown-values.js"
import { createBot, decodeBot, setUpWith } from "./bot-test-support.js"

interface Member {
  readonly id: string
  readonly name: string
  readonly publicKey: string
}

const studio: Member = { id: "machine-studio", name: "Studio", publicKey: "studio-key" }
const laptop: Member = { id: "machine-laptop", name: "Laptop", publicKey: "laptop-key" }
const stranger: Member = { id: "machine-stranger", name: "Stranger", publicKey: "stranger-key" }

interface FleetMachine {
  readonly agents: Awaited<ReturnType<typeof makeServices>>["agents"]
  readonly server: RunningCodevisorServer
  readonly fleetTickets: FleetTickets
  readonly machines: MachineLink
}

type Fleet = Map<string, FleetMachine>

const startMachine = async (self: Member, fleet: Fleet): Promise<FleetMachine> => {
  const { agents, services } = await makeServices(self.id)
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
    invoke: (machine, path, args, origin) =>
      callAs(self, fleet.get(machine)!, { path, args: args ?? null, origin })
  }
  const server = await run(
    startCodevisorServer(
      { ...services, machines, fleetTickets },
      defaultServerConfig({ bootId: "test-boot", id: self.id, port: 0 })
    )
  )
  runningServers.push(server)
  const machine = { agents, server, fleetTickets, machines }
  fleet.set(self.id, machine)
  return machine
}

const callAs = async (
  caller: Member,
  target: FleetMachine,
  body: { readonly path: string; readonly args: unknown; readonly origin: MachineCallOrigin }
): Promise<unknown> => {
  const answer = await withTicket(
    target.fleetTickets.callers,
    { deviceId: caller.id, publicKey: caller.publicKey },
    (ticket) => postInvoke(target.server.url, body, { [FLEET_CALLER_HEADER]: ticket })
  )
  if (answer.status !== 200) throw new Error(JSON.stringify(answer.body))
  return resultOf(answer.body)
}

type FleetTickets = ReturnType<typeof makeFleetTickets>

const postInvoke = async (url: string, body: unknown, headers: Record<string, string> = {}) => {
  const response = await fetch(`${url}/v1/gateway/invoke`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body)
  })
  return { status: response.status, body: (await response.json()) as unknown }
}

const resultOf = (body: unknown): unknown => (isRecord(body) ? body.result : undefined)

const createdSession = (result: unknown): SessionSummary => decode(SessionSummary)(result)

const workspaces = async (machine: { readonly server: Parameters<typeof jsonRequest>[0] }) =>
  decode(Schema.Array(Workspace))((await jsonRequest(machine.server, "/v1/workspaces")).body)

const workspaceOf = async (
  machine: { readonly server: Parameters<typeof jsonRequest>[0] },
  session: SessionSummary
) => (await workspaces(machine)).find((workspace) => workspace.id === session.workspaceId)

const startFleet = async () => {
  const fleet: Fleet = new Map()
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
  return { home, remote, bot, botOrigin }
}

const createArgs = { projectId: "laptop-project", harnessId: "codex", title: "Fix the laptop" }

describe("bot sub-agents on another machine", () => {
  it("links a session the bot creates on another machine and wakes the bot when it ends a turn", async () => {
    const { home, remote, bot, botOrigin } = await startFleet()

    const child = createdSession(
      await home.machines.invoke(laptop.id, "codevisor.sessions.create", createArgs, botOrigin)
    )
    await jsonRequest(remote.server, `/v1/sessions/${child.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "status" })
    })

    expect(child.parentSessionId).toBe(`remote:${studio.id}:${bot.sessionId}`)
    expect(await workspaceOf(remote, child)).toMatchObject({
      botId: bot.id,
      botMachineId: studio.id
    })
    await waitFor(() =>
      home.agents.prompts.some(
        ([, input]) =>
          typeof input === "string" &&
          input.startsWith(
            `<codevisor-event machine="Laptop" machineId="${laptop.id}" type="session.turn_ended" sessionId="${child.id}" title="Fix the laptop"`
          )
      )
    )
  })

  it("ignores a bot claim that doesn't come from the claimed machine", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const create = (body: unknown, headers?: Record<string, string>) =>
      postInvoke(remote.server.url, body, headers).then((answer) => {
        expect(answer.status).toBe(200)
        return createdSession(resultOf(answer.body))
      })

    const anonymous = await create({
      path: "codevisor.sessions.create",
      args: createArgs,
      origin: botOrigin
    })
    const impostor = await withTicket(
      remote.fleetTickets.callers,
      { deviceId: stranger.id, publicKey: stranger.publicKey },
      (ticket) =>
        create(
          { path: "codevisor.sessions.create", args: createArgs, origin: botOrigin },
          { [FLEET_CALLER_HEADER]: ticket }
        )
    )
    const stolenKey = await withTicket(
      remote.fleetTickets.callers,
      { deviceId: studio.id, publicKey: stranger.publicKey },
      (ticket) =>
        create(
          { path: "codevisor.sessions.create", args: createArgs, origin: botOrigin },
          { [FLEET_CALLER_HEADER]: ticket }
        )
    )
    const otherMachine = createdSession(
      await home.machines.invoke(laptop.id, "codevisor.sessions.create", createArgs, {
        ...botOrigin,
        machineId: stranger.id
      })
    )
    const direct = decode(SessionSummary)(
      (
        await jsonRequest(remote.server, "/v1/sessions", {
          method: "POST",
          headers: { [BOT_LINK_HEADER]: "forged" },
          body: JSON.stringify({
            ...createArgs,
            workspaceId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
            parentSessionId: `remote:${studio.id}:${botOrigin.sessionId}`
          })
        })
      ).body
    )

    for (const session of [anonymous, impostor, stolenKey, otherMachine, direct]) {
      const workspace = await workspaceOf(remote, session)
      expect(workspace).toBeDefined()
      expect(workspace?.botId).toBeUndefined()
    }
  })

  it("links back to a bot on this machine when a remote sub-agent of that bot starts more work here", async () => {
    const { home, remote } = await startFleet()
    const localBot = decodeBot(
      (await createBot(remote, { projectIds: ["laptop-project"], conversational: true })).body
    )
    const fromSubAgent = (botId: string) =>
      home.machines.invoke(laptop.id, "codevisor.sessions.create", createArgs, {
        machineId: studio.id,
        machineName: studio.name,
        sessionId: "11111111-2222-4333-8444-555555555555",
        botId,
        botMachineId: laptop.id
      })

    const linked = createdSession(await fromSubAgent(localBot.id))
    const unknown = createdSession(await fromSubAgent("99999999-2222-4333-8444-555555555555"))

    const linkedWorkspace = await workspaceOf(remote, linked)
    expect(linkedWorkspace?.botId).toBe(localBot.id)
    expect(linkedWorkspace?.botMachineId).toBeUndefined()
    expect((await workspaceOf(remote, unknown))?.botId).toBeUndefined()
  })

  it("delivers fleet events only from verified machines to sessions that exist", async () => {
    const { home, bot } = await startFleet()
    const event = { sessionId: bot.sessionId, key: "turn_ended:x", text: "<codevisor-event/>" }
    const origin = { machineId: laptop.id, machineName: laptop.name, sessionId: "x" }

    const unverified = await postInvoke(home.server.url, {
      path: FLEET_SESSION_EVENT_PATH,
      args: event,
      origin
    })
    const missing = withTicket(
      home.fleetTickets.callers,
      { deviceId: laptop.id, publicKey: laptop.publicKey },
      (ticket) =>
        postInvoke(
          home.server.url,
          { path: FLEET_SESSION_EVENT_PATH, args: { ...event, sessionId: "nobody" }, origin },
          { [FLEET_CALLER_HEADER]: ticket }
        )
    )
    const malformed = await Promise.all(
      ["not an event", { sessionId: bot.sessionId }, { ...event, text: 4 }].map((args) =>
        withTicket(
          home.fleetTickets.callers,
          { deviceId: laptop.id, publicKey: laptop.publicKey },
          (ticket) =>
            postInvoke(
              home.server.url,
              { path: FLEET_SESSION_EVENT_PATH, args, origin },
              { [FLEET_CALLER_HEADER]: ticket }
            )
        )
      )
    )

    expect([unverified.status, (await missing).status]).toEqual([403, 404])
    expect(malformed.map((answer) => answer.status)).toEqual([400, 400, 400])
  })
})
