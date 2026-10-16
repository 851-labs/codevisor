import * as acp from "@agentclientprotocol/sdk"
import type { AcpAgentConnection } from "@codevisor/adapter-acp"
import { AgentRuntimeError } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { makeGrokBuildExtension } from "./extension.js"

const FLUSH_METHOD = "_codevisor/test_flush"
const connections: Array<acp.AgentConnection> = []

afterEach(() => {
  for (const connection of connections.splice(0)) connection.close()
})

const retryState = (errorType: string) => ({
  sessionId: "s-1",
  update: { sessionUpdate: "retry_state", type: "failed", error_type: errorType, message: "401" }
})

class FailingConnection implements AcpAgentConnection {
  constructor(private readonly beforeFailing: () => Promise<void>) {}

  createSession(cwd: string) {
    return Effect.succeed({ configOptions: [], cwd, sessionId: "s-1" })
  }

  loadSession(sessionId: string) {
    return Effect.succeed({ configOptions: [], sessionId })
  }

  prompt() {
    return Effect.promise(this.beforeFailing).pipe(
      Effect.flatMap(() =>
        Effect.fail(new AgentRuntimeError({ message: "Internal error", operation: "prompt" }))
      )
    )
  }

  cancel() {
    return Effect.void
  }

  setMode() {
    return Effect.void
  }

  setConfigOption() {
    return Effect.succeed([])
  }

  probeAuth() {
    return Effect.succeed({
      canLogout: false as const,
      methods: [] as const,
      state: "notRequired" as const
    })
  }

  authenticate() {
    return Effect.void
  }

  readonly logout = Effect.void
  readonly close = Effect.void
}

const promptFailingAfter = (errorType: string | undefined) => {
  const extension = makeGrokBuildExtension({
    emit: () => undefined,
    enqueueQuestion: () => new Promise(() => undefined)
  })
  const app = new acp.ClientApp().onRequest<unknown, Record<string, never>>(
    FLUSH_METHOD,
    (params) => params,
    () => ({})
  )
  const agent = new acp.AgentApp().connect(extension.configureClientApp?.(app) ?? app)
  connections.push(agent)
  const base = new FailingConnection(async () => {
    if (errorType === undefined) return
    await agent.client.notify("_x.ai/session_notification", retryState(errorType))
    await agent.client.request(FLUSH_METHOD, {})
  })
  const extended = extension.sdkConnectionCustomization?.extendConnection?.(base, {
    connection: new acp.ClientApp().connect(new acp.AgentApp())
  })
  if (extended === undefined) throw new Error("Grok connection extension was not installed")
  return Effect.runPromise(extended.prompt("s-1", "hi"))
}

describe("Grok Build sign-in failures", () => {
  it("ends a prompt Grok failed for authentication as needing sign-in", async () => {
    expect(await promptFailingAfter("auth")).toEqual({
      stopKind: "authRequired",
      stopReason: "end_turn"
    })
  })

  it("keeps failing prompts Grok expects to recover from, or that weren't about sign-in", async () => {
    await expect(promptFailingAfter("auth_transient")).rejects.toMatchObject({
      message: "Internal error"
    })
    await expect(promptFailingAfter(undefined)).rejects.toMatchObject({
      message: "Internal error"
    })
  })
})
