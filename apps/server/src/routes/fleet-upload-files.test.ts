import { FLEET_UPLOAD_FILES_PATH } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeFleetTickets, withTicket } from "../infra/fleet-tickets.js"
import { makeServices, startWithApp } from "../test-support.js"
import { postInvoke } from "./fleet-test-support.js"

const origin = { machineId: "server-studio", machineName: "Mac Studio" }
const caller = { deviceId: "device-studio", publicKey: "pk" }
const report = { name: "report.pdf", data: Buffer.from("%PDF").toString("base64") }

const startAgentMachine = async () => {
  const { services } = await makeServices("server-laptop")
  const reads: Array<{ sessionId: string; paths: ReadonlyArray<string> }> = []
  const tickets = makeFleetTickets()
  const server = await startWithApp({
    ...services,
    fleetTickets: tickets,
    machines: {
      list: () => Promise.resolve([]),
      resolve: () => undefined,
      invoke: () => Promise.reject(new Error("unused")),
      machineIdOf: (peer) => (peer.deviceId === caller.deviceId ? origin.machineId : undefined),
      isGone: () => false
    },
    mcp: {
      ...services.mcp,
      readUploadFiles: async (sessionId, paths) => {
        reads.push({ sessionId, paths })
        return { files: [report] }
      }
    }
  })
  const send = (args: unknown, verified = true) => {
    const body = { path: FLEET_UPLOAD_FILES_PATH, args, origin }
    if (!verified) return postInvoke(server.url, body)
    return withTicket(tickets.callers, caller, (ticket) =>
      postInvoke(server.url, body, { "x-codevisor-fleet-caller": ticket })
    )
  }
  return { reads, send }
}

describe("upload files requested by another machine", () => {
  it("hands a chat's files only to machines on the account that ask properly", async () => {
    const agent = await startAgentMachine()
    const request = { sessionId: "chat-1", paths: ["docs/report.pdf"] }

    const answers = [
      await agent.send(request, false),
      await agent.send({ sessionId: "chat-1" }),
      await agent.send(request)
    ]

    expect(answers).toEqual([
      {
        status: 403,
        body: { error: { message: "Only machines on this account can fetch uploads" } }
      },
      { status: 400, body: { error: { message: "Expected { sessionId, paths }" } } },
      { status: 200, body: { result: { files: [report] } } }
    ])
    expect(agent.reads).toEqual([request])
  })
})
