import { describe, expect, it } from "vitest"

import { makeFleetTickets, withTicket } from "./fleet-tickets.js"

describe("fleet tickets", () => {
  it("hands a ticket's value out once, and never after it is revoked", async () => {
    const { callers } = makeFleetTickets()
    const peer = { deviceId: "device-a", publicKey: "key-a" }

    const reads = await withTicket(callers, peer, async (ticket) => [
      callers.take(ticket),
      callers.take(ticket)
    ])
    const leftOver = callers.issue(peer)
    callers.revoke(leftOver)

    expect(reads).toEqual([peer, undefined])
    expect(callers.take(leftOver)).toBeUndefined()
    expect(callers.take(undefined)).toBeUndefined()
  })

  it("revokes an unused ticket when the work fails", async () => {
    const { remoteParents } = makeFleetTickets()
    let issued = ""

    const failed = withTicket(
      remoteParents,
      { parentSessionId: "remote:a:s", bot: { botId: "b" } },
      async (ticket) => {
        issued = ticket
        throw new Error("boom")
      }
    )

    await expect(failed).rejects.toThrow("boom")
    expect(remoteParents.take(issued)).toBeUndefined()
  })
})
