import { decode, FLEET_AGENTS_MOVED_PATH, SessionSummary } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import {
  invokeAs,
  laptop,
  postInvoke,
  resultOf,
  startArgs,
  startedSession,
  startFleet,
  studio,
  type FleetMachine
} from "./fleet-test-support.js"

const fromStudio = { machineId: studio.id, machineName: studio.name }
const fromLaptop = { machineId: laptop.id, machineName: laptop.name }

const creatorOf = async (machine: FleetMachine, sessionId: string) => {
  const detail = (await jsonRequest(machine.server, `/v1/sessions/${sessionId}`)).body
  return decode(Schema.Struct({ session: SessionSummary }))(detail).session.createdByAgentId
}

describe("moving an agent's agents that run on another machine", () => {
  it("moves only the agents that machine says the agent started there", async () => {
    const { home, remote, parent, parentOrigin } = await startFleet()
    const child = await startedSession(
      remote,
      await home.machines.invoke(
        laptop.id,
        "codevisor.agents.start",
        startArgs("one"),
        parentOrigin
      )
    )
    const move = { fromAgentId: parent.id, toAgentId: "forked-bot-session" }

    const fromOtherMachine = await invokeAs(laptop, home, {
      path: FLEET_AGENTS_MOVED_PATH,
      args: move,
      origin: fromLaptop
    })
    const unverified = await postInvoke(remote.server.url, {
      path: FLEET_AGENTS_MOVED_PATH,
      args: move,
      origin: fromStudio
    })
    const malformed = await invokeAs(studio, remote, {
      path: FLEET_AGENTS_MOVED_PATH,
      args: { fromAgentId: parent.id },
      origin: fromStudio
    })
    const fromCreatorMachine = await invokeAs(studio, remote, {
      path: FLEET_AGENTS_MOVED_PATH,
      args: move,
      origin: fromStudio
    })

    expect(resultOf(fromOtherMachine.body)).toEqual({ moved: 0 })
    expect([unverified.status, malformed.status]).toEqual([403, 400])
    expect(resultOf(fromCreatorMachine.body)).toEqual({ moved: 1 })
    expect(await creatorOf(remote, child.id)).toBe("forked-bot-session")
  })
})
