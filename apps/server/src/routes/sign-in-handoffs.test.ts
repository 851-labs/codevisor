import { describe, expect, it } from "vitest"

import { makeSignInHandoffs, signInTicket } from "./sign-in-handoffs.js"

const ticket = (index: number): string => `ticket-${String(index).padStart(12, "0")}`

const never = (): Promise<void> => new Promise(() => undefined)

describe("sign-in handoffs", () => {
  it("hands the browser the sign-in URL whether it arrives before or after the browser asks", async () => {
    const handoffs = makeSignInHandoffs({ sleep: never })
    const early = { authorizationUrl: "https://auth.example.test/authorize?state=early" }
    const late = { authorizationUrl: "https://auth.example.test/authorize?state=late" }

    handoffs.settle(ticket(1), early)
    const waiting = handoffs.wait(ticket(2))
    handoffs.settle(ticket(2), late)
    handoffs.settle(ticket(2), { failure: "ignored once settled" })
    handoffs.settle(undefined, { failure: "no browser is waiting" })

    expect([await handoffs.wait(ticket(1)), await waiting]).toEqual([early, late])
  })

  it("tells a waiting browser when sign-in never starts", async () => {
    const { promise: elapsed, resolve: elapse } = Promise.withResolvers<void>()
    const handoffs = makeSignInHandoffs({ sleep: () => elapsed })
    const waiting = handoffs.wait(ticket(1))

    elapse()

    expect(await waiting).toEqual({
      failure: "Sign-in took too long to start. Try again from Codevisor."
    })
  })

  it("gives up on the oldest browsers once too many are waiting", async () => {
    const handoffs = makeSignInHandoffs({ sleep: never })
    const oldest = handoffs.wait(ticket(0))

    for (let index = 1; index <= 64; index += 1) void handoffs.wait(ticket(index))

    expect(await oldest).toMatchObject({ failure: expect.stringContaining("took too long") })
  })

  it("accepts only tickets shaped like the ones the app makes", () => {
    expect(
      [
        "0F3C2B1A-9D8E-4F7A-B6C5-D4E3F2A1B0C9",
        "short",
        "has/slash-0000000000000",
        "",
        null,
        undefined
      ].map(signInTicket)
    ).toEqual([
      "0F3C2B1A-9D8E-4F7A-B6C5-D4E3F2A1B0C9",
      undefined,
      undefined,
      undefined,
      undefined,
      undefined
    ])
  })
})
