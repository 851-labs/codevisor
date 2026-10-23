import { decode, REMOTE_PARENT_HEADER, remoteSessionKey, SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { withTicket } from "../infra/fleet-tickets.js"
import { jsonRequest, run, waitFor } from "../test-support.js"
import { createBot, decodeBot, endedTurns } from "./bot-test-support.js"
import { fleetBotWake } from "./fleet-session-events.js"
import {
  createArgs,
  invokeAs,
  laptop,
  post,
  postInvoke,
  startArgs,
  startedSession,
  startFleet,
  stranger,
  studio,
  workspaceOf,
  type Answer,
  type FleetMachine
} from "./fleet-test-support.js"

const refusedRemoteParent = (answer: Answer) => {
  expect(answer.status).not.toBe(200)
  expect(JSON.stringify(answer.body)).toContain("owns a remote parent session")
}

const createLocally = async (machine: FleetMachine, body: Record<string, unknown>) =>
  post(machine, "/v1/sessions", { ...createArgs, ...body })

const escapeRegExp = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

const failureOf = (pending: Promise<unknown>): Promise<string> =>
  pending.then(
    () => "",
    (cause: unknown) => String(cause)
  )

const sessionCount = async (machine: FleetMachine) =>
  (await run(machine.services.db.listSessions)).length

describe("bot sub-agents on another machine", () => {
  it("links a session the bot creates on another machine and wakes the bot with each turn's own reply", async () => {
    const { home, remote, bot, botOrigin } = await startFleet()
    const reports = () =>
      home.agents.prompts.flatMap(([, input]) =>
        typeof input === "string" && input.includes('type="session.turn_ended"') ? [input] : []
      )

    const child = await startedSession(
      remote,
      await home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("one"), botOrigin)
    )
    await waitFor(() => reports().length === 1)
    await post(remote, `/v1/sessions/${child.id}/prompt`, { text: "two" })
    await waitFor(() => reports().length === 2)

    expect(child.parentSessionId).toBe(remoteSessionKey(studio.id, bot.sessionId))
    expect(await workspaceOf(remote, child)).toMatchObject({
      botId: bot.id,
      botMachineId: studio.id
    })
    const opening = `<codevisor-event machine="Laptop" machineId="${laptop.id}" type="session.turn_ended" agentId="${child.id}" title="Fix the laptop"`
    expect(reports()).toEqual([
      expect.stringMatching(new RegExp(`^${escapeRegExp(opening)}.*\\nEcho: one\\n`, "s")),
      expect.stringMatching(new RegExp(`^${escapeRegExp(opening)}.*\\nEcho: two\\n`, "s"))
    ])
  })

  it("refuses a remote parent that doesn't come from its own machine", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const create = { path: "codevisor.agents.start", args: startArgs("go"), origin: botOrigin }
    const before = await sessionCount(remote)

    const anonymous = await postInvoke(remote.server.url, create)
    const impostor = await invokeAs(stranger, remote, create)
    const stolenKey = await invokeAs({ ...studio, publicKey: stranger.publicKey }, remote, create)
    const otherMachine = await failureOf(
      home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("go"), {
        ...botOrigin,
        machineId: stranger.id
      })
    )
    const direct = await jsonRequest(remote.server, "/v1/sessions", {
      method: "POST",
      headers: { [REMOTE_PARENT_HEADER]: "forged" },
      body: JSON.stringify({ ...createArgs, parentSessionId: remoteSessionKey(studio.id, "x") })
    })
    const directWorkspace = await post(remote, "/v1/workspaces", {
      workspace: {
        id: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
        projectId: "laptop-project",
        name: "W",
        hasCustomName: true
      },
      session: { ...createArgs, parentSessionId: `remote:${studio.id}:x` }
    })

    for (const answer of [anonymous, impostor, stolenKey, direct, directWorkspace]) {
      refusedRemoteParent(answer)
    }
    expect(otherMachine).toContain("owns a remote parent session")
    expect(await sessionCount(remote)).toBe(before)
  })

  it("lets a verified machine start chats without a bot, and never wakes anything for them", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const { botId: _botId, ...withoutBot } = botOrigin

    const child = await startedSession(
      remote,
      await home.machines.invoke(
        laptop.id,
        "codevisor.agents.start",
        startArgs("status"),
        withoutBot
      )
    )

    const thirdMachineBot = await startedSession(
      remote,
      await home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("status"), {
        ...botOrigin,
        botMachineId: "machine-third"
      })
    )
    await waitFor(() => endedTurns(remote, child.id) > 0)

    expect(child.parentSessionId).toBe(remoteSessionKey(studio.id, botOrigin.sessionId))
    expect((await workspaceOf(remote, child))?.botId).toBeUndefined()
    expect(await fleetBotWake(remote.services, child)).toBeUndefined()
    expect(await workspaceOf(remote, thirdMachineBot)).toMatchObject({
      botMachineId: "machine-third"
    })
    expect(await fleetBotWake(remote.services, thirdMachineBot)).toBeUndefined()
  })

  it("keeps ordinary callers out of a workspace that belongs to another machine's bot", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const child = await startedSession(
      remote,
      await home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("go"), botOrigin)
    )
    const plain = decode(SessionSummary)((await createLocally(remote, {})).body)
    const intoLinked = (body: Record<string, unknown>) =>
      createLocally(remote, { workspaceId: child.workspaceId, ...body })

    const remoteParent = await intoLinked({ parentSessionId: `remote:${studio.id}:other` })
    const unrelatedParent = await intoLinked({ parentSessionId: plain.id })
    const moved = await post(
      remote,
      `/v1/sessions/${plain.id}`,
      { workspaceId: child.workspaceId },
      "PATCH"
    )
    const asVerifiedParent = (sessionId: string) =>
      withTicket(
        remote.fleetTickets.remoteParents,
        {
          parentSessionId: remoteSessionKey(studio.id, sessionId),
          bot: { botId: botOrigin.botId!, botMachineId: studio.id }
        },
        (ticket) =>
          jsonRequest(remote.server, "/v1/sessions", {
            method: "POST",
            headers: { [REMOTE_PARENT_HEADER]: ticket },
            body: JSON.stringify({
              ...createArgs,
              workspaceId: child.workspaceId,
              parentSessionId: remoteSessionKey(studio.id, sessionId)
            })
          })
      )
    const otherBotSession = await asVerifiedParent("11111111-2222-4333-8444-555555555555")
    const sameBotSession = await asVerifiedParent(botOrigin.sessionId!)
    const grandchild = await intoLinked({ parentSessionId: child.id })
    const plainTab = await intoLinked({})

    refusedRemoteParent(remoteParent)
    expect([unrelatedParent.status, moved.status]).toEqual([409, 409])
    expect(JSON.stringify(otherBotSession.body)).toContain("belongs to a bot on another machine")
    expect(sameBotSession.status).toBe(201)
    expect([grandchild.status, plainTab.status]).toEqual([201, 201])
    const joined = [grandchild, plainTab].map((answer) => decode(SessionSummary)(answer.body))
    for (const session of joined) {
      expect(await fleetBotWake(remote.services, session)).toBeUndefined()
    }
    expect(await fleetBotWake(remote.services, child)).toMatchObject({
      subscriber: { machineId: studio.id, sessionId: botOrigin.sessionId }
    })
  })

  it("never lets an existing chat into a remote bot's workspace or links an existing workspace later", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const child = await startedSession(
      remote,
      await home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("go"), botOrigin)
    )
    const legacy = await run(
      remote.services.db.createSession({ ...createArgs, parentSessionId: child.parentSessionId })
    )
    const intoWorkspace = (workspaceId: string) =>
      post(remote, "/v1/workspaces", {
        workspace: { id: workspaceId, projectId: "laptop-project", name: "W", hasCustomName: true },
        session: { id: legacy.id, projectId: "laptop-project", harnessId: "codex" }
      })
    const freshWorkspace = "0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3"

    const movedIntoLinked = await intoWorkspace(child.workspaceId!)
    const movedIntoFresh = await intoWorkspace(freshWorkspace)

    expect([movedIntoLinked.status, movedIntoFresh.status]).toEqual([409, 200])
    const moved = await run(remote.services.db.getSessionSummary(legacy.id))
    expect(await fleetBotWake(remote.services, moved)).toBeUndefined()
  })

  it("links back to a bot on this machine when a remote sub-agent of that bot starts more work here", async () => {
    const { home, remote } = await startFleet()
    const localBot = decodeBot(
      (await createBot(remote, { projectIds: ["laptop-project"], conversational: true })).body
    )
    const fromSubAgent = (botId: string) =>
      home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("go"), {
        machineId: studio.id,
        machineName: studio.name,
        sessionId: "11111111-2222-4333-8444-555555555555",
        botId,
        botMachineId: laptop.id
      })

    const linked = await startedSession(remote, await fromSubAgent(localBot.id))
    const unknown = await startedSession(
      remote,
      await fromSubAgent("99999999-2222-4333-8444-555555555555")
    )

    const linkedWorkspace = await workspaceOf(remote, linked)
    expect(linkedWorkspace?.botId).toBe(localBot.id)
    expect(linkedWorkspace?.botMachineId).toBeUndefined()
    expect((await workspaceOf(remote, unknown))?.botId).toBeUndefined()
  })
})
