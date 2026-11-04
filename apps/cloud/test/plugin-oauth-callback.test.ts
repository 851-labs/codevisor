import { env } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import worker from "../src/index.js"
import { BASE } from "./cloud-test-support.js"

const flowId = "Qm9nT3V0RmxvdzAxMjM0NTY3ODlhYmNk"
const nonce = "bm9uY2UwMTIz"

const callback = async (query: Record<string, string>) =>
  worker.fetch(
    new Request(`${BASE}/oauth/plugins/callback?${new URLSearchParams(query).toString()}`, {
      redirect: "manual"
    }),
    env
  )

describe("plugin OAuth callback", () => {
  it("returns the code to the Codevisor app named in the state, and nothing else", async () => {
    const state = `${flowId}.codevisor-dev-ff7f4cf1a4.${nonce}`

    const response = await callback({
      code: "lin-code",
      state,
      iss: "https://linear.app",
      extra: "x"
    })

    expect(response.status).toBe(302)
    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(response.headers.get("location")).toBe(
      `codevisor-dev-ff7f4cf1a4://plugin-oauth?${new URLSearchParams({ state, code: "lin-code" }).toString()}`
    )
  })

  it("passes a provider's error back to the app so it can say the sign-in was cancelled", async () => {
    const state = `${flowId}.codevisor.${nonce}`

    const response = await callback({ state, error: "access_denied", error_description: "No" })

    expect(response.headers.get("location")).toBe(
      `codevisor://plugin-oauth?${new URLSearchParams({ state, error: "access_denied", error_description: "No" }).toString()}`
    )
  })

  it("refuses states that don't name a Codevisor app scheme", async () => {
    const states = [
      "",
      `${flowId}.local.${nonce}`,
      `${flowId}.javascript.${nonce}`,
      `${flowId}.codevisor-dev-ff7f4cf1a4x.${nonce}`,
      `${flowId}.https://evil.example.${nonce}`
    ]

    const responses = await Promise.all(states.map((state) => callback({ code: "c", state })))

    expect(
      responses.map((response) => [response.status, response.headers.get("location")])
    ).toEqual(states.map(() => [400, null]))
  })
})
