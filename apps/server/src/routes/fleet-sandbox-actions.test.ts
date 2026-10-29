import { FLEET_SANDBOX_ACTION_PATH } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeFleetTickets, withTicket } from "../infra/fleet-tickets.js"
import { sandboxHarness } from "../infra/sandbox-test-support.js"
import type { CodevisorServerServices } from "../server-context.js"
import { makeServices, startWithApp } from "../test-support.js"
import { postInvoke } from "./fleet-test-support.js"

const origin = { machineId: "server-laptop", machineName: "Laptop" }
const caller = { deviceId: "device-laptop", publicKey: "pk" }

const startReceiver = async (sandboxes: CodevisorServerServices["sandboxes"]) => {
  const { services } = await makeServices("server-studio")
  const tickets = makeFleetTickets()
  const server = await startWithApp({
    ...services,
    fleetTickets: tickets,
    machines: {
      list: () => Promise.resolve([]),
      resolve: () => undefined,
      invoke: () => Promise.reject(new Error("unused")),
      machineIdOf: (peer) => (peer.deviceId === caller.deviceId ? origin.machineId : undefined)
    },
    ...(sandboxes === undefined ? {} : { sandboxes })
  })
  const send = (args: unknown, verified = true) => {
    const body = { path: FLEET_SANDBOX_ACTION_PATH, args, origin }
    if (!verified) return postInvoke(server.url, body)
    return withTicket(tickets.callers, caller, (ticket) =>
      postInvoke(server.url, body, { "x-codevisor-fleet-caller": ticket })
    )
  }
  return { send }
}

const destroy = {
  request: { action: "destroy", id: "missing" },
  record: {
    key: "other",
    value: null,
    deleted: true,
    timestamp: { wallMs: 1, counter: 0, deviceId: "d" }
  }
}

describe("sandbox actions from other machines", () => {
  it("only takes well-formed actions from machines on the account, on machines that run sandboxes", async () => {
    const harness = await sandboxHarness()
    const receiver = await startReceiver({ sandboxes: harness.machines, catalog: harness.catalog })
    const without = await startReceiver(undefined)

    const answers = await Promise.all([
      receiver.send(destroy, false),
      receiver.send({ ...destroy, request: { action: "pause", id: "box" } }),
      receiver.send(destroy),
      without.send(destroy)
    ])

    expect(answers).toEqual([
      {
        status: 403,
        body: { error: { message: "Only machines on this account can manage sandboxes" } }
      },
      { status: 400, body: { error: { message: "Expected { request, record }" } } },
      { status: 404, body: { error: { message: "No sandbox missing" } } },
      { status: 501, body: { error: { message: "Sandboxes are unavailable here" } } }
    ])
  })
})
