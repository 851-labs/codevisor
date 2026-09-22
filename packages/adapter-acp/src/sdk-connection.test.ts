import * as acp from "@agentclientprotocol/sdk"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { sdkConnection } from "./sdk-connection.js"

const authRequired = Object.assign(new Error("Authentication required"), {
  code: -32000,
  data: "no auth method id provided"
})

const fakeConnection = (request: ReturnType<typeof vi.fn>) =>
  ({
    agent: { request },
    closed: new Promise<void>(() => {})
  }) as unknown as acp.ClientConnection

const newSession = { sessionId: "s-1", configOptions: [] }

describe("sdkConnection.createSession", () => {
  it("selects a host-provided auth method and retries once when the agent asks for authentication", async () => {
    const request = vi.fn(async (method: string, _params?: unknown) => {
      if (method === acp.methods.agent.session.new) {
        return request.mock.calls.some(([m]) => m === acp.methods.agent.authenticate)
          ? newSession
          : Promise.reject(authRequired)
      }
      return {}
    })
    const connection = sdkConnection(fakeConnection(request), () => "", {
      auth: {
        methods: [{ id: "grok.com", name: "Codevisor", external: true }],
        canLogout: false
      }
    })
    const metadata = await Effect.runPromise(connection.createSession("/tmp", undefined))
    expect(metadata.sessionId).toBe("s-1")
    expect(request.mock.calls.map(([method]) => method)).toEqual([
      acp.methods.agent.session.new,
      acp.methods.agent.authenticate,
      acp.methods.agent.session.new
    ])
    expect(request.mock.calls[1]?.[1]).toEqual({ methodId: "grok.com" })
  })

  it("does not authenticate on the user's behalf for interactive methods", async () => {
    const request = vi.fn(async (method: string) =>
      method === acp.methods.agent.session.new ? Promise.reject(authRequired) : {}
    )
    const connection = sdkConnection(fakeConnection(request), () => "", {
      auth: { methods: [{ id: "browser", name: "Sign in" }], canLogout: false }
    })
    await expect(
      Effect.runPromise(connection.createSession("/tmp", undefined))
    ).rejects.toMatchObject({ operation: "createSession" })
    expect(request).toHaveBeenCalledTimes(1)
  })

  it("surfaces non-auth failures unchanged, without retrying", async () => {
    const request = vi.fn(async (method: string) =>
      method === acp.methods.agent.session.new ? Promise.reject(new Error("boom")) : {}
    )
    const connection = sdkConnection(fakeConnection(request), () => "", {
      auth: { methods: [{ id: "grok.com", name: "Codevisor", external: true }], canLogout: false }
    })
    await expect(
      Effect.runPromise(connection.createSession("/tmp", undefined))
    ).rejects.toMatchObject({ operation: "createSession" })
    expect(request).toHaveBeenCalledTimes(1)
  })
})
