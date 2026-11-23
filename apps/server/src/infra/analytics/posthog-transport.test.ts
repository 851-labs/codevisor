import { describe, expect, it } from "vitest"

import { postHogSender } from "./posthog-transport.js"

describe("postHogSender", () => {
  it("posts one event with the project token to the capture endpoint", async () => {
    const requests: Request[] = []
    const send = postHogSender(
      { projectToken: "phc_test", host: "https://us.i.posthog.com" },
      async (url, init) => {
        requests.push(new Request(url, init))
        return new Response(null, { status: 200 })
      }
    )

    await send({
      event: "agent layout changed",
      distinct_id: "m",
      timestamp: "t",
      properties: { a: 1 }
    })

    expect(requests[0]?.url).toBe("https://us.i.posthog.com/i/v0/e/")
    expect(await requests[0]?.json()).toEqual({
      api_key: "phc_test",
      event: "agent layout changed",
      distinct_id: "m",
      timestamp: "t",
      properties: { a: 1 }
    })
  })
})
