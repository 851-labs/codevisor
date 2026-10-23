import { describe, expect, it } from "vitest"

import type { FleetLink } from "../infra/fleet-outbox.js"
import { makeServices, run } from "../test-support.js"
import { sendFinishedFleetTurns } from "./fleet-turns.js"

const parent = "remote2:machine-studio:bot-chat"
const botId = "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10"

const fleetLink = (current: ReadonlyArray<string>) => {
  const flushes: string[] = []
  const fleet: FleetLink = {
    machines: {
      list: async () =>
        current.map((name) => ({ id: "machine-laptop", name, online: true, isCurrent: true })),
      resolve: () => undefined,
      machineIdOf: () => undefined,
      invoke: async () => null
    },
    outbox: {
      flush: async () => {
        flushes.push("flush")
      },
      expire: async () => undefined
    }
  }
  return { fleet, flushes }
}

const childOfBot = async (
  services: Awaited<ReturnType<typeof makeServices>>["services"],
  projectId: string,
  workspaceId: string,
  botMachineId: string
) => {
  const { session } = await run(
    services.db.createWorkspaceWithSession({
      workspace: {
        id: workspaceId,
        projectId,
        name: "Sub-agent",
        hasCustomName: false,
        botId,
        botMachineId,
        botParentSessionId: parent
      },
      session: { projectId, harnessId: "codex", title: "Fix the laptop", parentSessionId: parent }
    })
  )
  await run(
    services.db.appendEvent("session.updated", session.id, {
      turnState: "ended",
      stopReason: "end_turn"
    })
  )
  return session
}

describe("finished turns of another machine's bot children", () => {
  it("queues one wake-up per finished turn for the bot's own machine, and drops the rest", async () => {
    const { services } = await makeServices("machine-laptop")
    const project = await run(services.db.createProject({ folderPath: "/tmp/fleet-turns" }))
    const child = await childOfBot(
      services,
      project.id,
      "a8a0d4f4-61c4-4a4e-8b1a-4f2f6e7c9b01",
      "machine-studio"
    )
    await childOfBot(services, project.id, "0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3", "machine-third")
    const gone = await childOfBot(
      services,
      project.id,
      "11111111-2222-4333-8444-555555555555",
      "machine-studio"
    )
    await run(services.db.deleteSession(gone.id))
    const unnamed = fleetLink([])
    const named = fleetLink(["Laptop"])

    await sendFinishedFleetTurns(services, { serverId: "machine-laptop", fleet: unnamed.fleet })
    await sendFinishedFleetTurns(services, { serverId: "machine-laptop", fleet: named.fleet })

    const queued = await run(services.db.listFleetMessages)
    expect(await run(services.db.listFleetPendingTurns)).toEqual([])
    expect([unnamed.flushes, named.flushes]).toEqual([["flush"], ["flush"]])
    expect(queued).toHaveLength(1)
    expect(queued[0]).toMatchObject({
      machineId: "machine-studio",
      path: "fleet.session_event",
      origin: {
        machineId: "machine-laptop",
        machineName: "machine-laptop",
        sessionId: child.id,
        sessionTitle: "Fix the laptop"
      },
      args: { sessionId: "bot-chat", botId, deliveryId: queued[0]!.id }
    })
    expect(queued[0]!.id).toMatch(new RegExp(`^machine-laptop:turn_ended:${child.id}:\\d+$`))
    expect(String(queued[0]!.args.text)).toMatch(
      /^<codevisor-event machine="machine-laptop" machineId="machine-laptop" type="session.turn_ended" .*stopReason="end_turn">/
    )
  })
})
