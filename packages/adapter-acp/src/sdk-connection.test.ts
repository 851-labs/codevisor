import * as acp from "@agentclientprotocol/sdk"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { sdkConnection } from "./sdk-connection.js"

const newSession = { sessionId: "s-1", configOptions: [] }

const fakeAgent = (createSession: (calls: ReadonlyArray<string>) => acp.NewSessionResponse) => {
  const calls: Array<string> = []
  const authentications: Array<acp.AuthenticateRequest> = []
  const agent = acp
    .agent({ name: "fake-agent" })
    .onRequest(acp.methods.agent.session.new, () => {
      calls.push(acp.methods.agent.session.new)
      return createSession(calls)
    })
    .onRequest(acp.methods.agent.authenticate, ({ params }) => {
      calls.push(acp.methods.agent.authenticate)
      authentications.push(params)
      return {}
    })
  return { authentications, calls, connection: acp.client({ name: "test" }).connect(agent) }
}

describe("sdkConnection.createSession", () => {
  it("selects a host-provided auth method and retries once when the agent asks for authentication", async () => {
    const agent = fakeAgent((calls) => {
      if (!calls.includes(acp.methods.agent.authenticate)) throw acp.RequestError.authRequired()
      return newSession
    })
    const connection = sdkConnection(agent.connection, () => "", {
      auth: {
        methods: [{ id: "grok.com", name: "Codevisor", external: true }],
        canLogout: false
      }
    })
    const metadata = await Effect.runPromise(connection.createSession("/tmp", undefined))
    expect(metadata.sessionId).toBe("s-1")
    expect(agent.calls).toEqual([
      acp.methods.agent.session.new,
      acp.methods.agent.authenticate,
      acp.methods.agent.session.new
    ])
    expect(agent.authentications).toEqual([{ methodId: "grok.com" }])
    await Effect.runPromise(connection.close)
  })

  it("does not authenticate on the user's behalf for interactive methods", async () => {
    const agent = fakeAgent(() => {
      throw acp.RequestError.authRequired()
    })
    const connection = sdkConnection(agent.connection, () => "", {
      auth: { methods: [{ id: "browser", name: "Sign in" }], canLogout: false }
    })
    await expect(
      Effect.runPromise(connection.createSession("/tmp", undefined))
    ).rejects.toMatchObject({ operation: "createSession" })
    expect(agent.calls).toEqual([acp.methods.agent.session.new])
    await Effect.runPromise(connection.close)
  })

  it("surfaces non-auth failures unchanged, without retrying", async () => {
    const agent = fakeAgent(() => {
      throw new Error("boom")
    })
    const connection = sdkConnection(agent.connection, () => "", {
      auth: { methods: [{ id: "grok.com", name: "Codevisor", external: true }], canLogout: false }
    })
    await expect(
      Effect.runPromise(connection.createSession("/tmp", undefined))
    ).rejects.toMatchObject({ operation: "createSession" })
    expect(agent.calls).toEqual([acp.methods.agent.session.new])
    await Effect.runPromise(connection.close)
  })
})
