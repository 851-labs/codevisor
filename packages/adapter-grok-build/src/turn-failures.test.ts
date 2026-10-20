import * as acp from "@agentclientprotocol/sdk"
import type { AcpAgentConnection } from "@codevisor/adapter-acp"
import { AgentRuntimeError, type RuntimeEvent } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { makeGrokBuildExtension } from "./extension.js"

const FLUSH_METHOD = "_codevisor/test_flush"
const connections: Array<{ readonly close: () => void }> = []

afterEach(() => {
  for (const connection of connections.splice(0)) connection.close()
})

type RetryState = Readonly<Record<string, unknown>>

const failed = (errorType: string, message: string): RetryState => ({
  type: "failed",
  error_type: errorType,
  message
})

const exhausted = (reason: string, isRateLimited = true): RetryState => ({
  type: "exhausted",
  attempts: 0,
  reason,
  is_rate_limited: isRateLimited
})

const retryStateNotification = (state: RetryState) => ({
  sessionId: "s-1",
  update: { sessionUpdate: "retry_state", ...state }
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

const promptFailingAfter = (state: RetryState | undefined) => {
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
    if (state === undefined) return
    await agent.client.notify("_x.ai/session_notification", retryStateNotification(state))
    await agent.client.request(FLUSH_METHOD, {})
  })
  const extended = extension.sdkConnectionCustomization?.extendConnection?.(base, {
    connection: new acp.ClientApp().connect(new acp.AgentApp())
  })
  if (extended === undefined) throw new Error("Grok connection extension was not installed")
  return Effect.runPromise(extended.prompt("s-1", "hi"))
}

const isTurnEnd = (event: RuntimeEvent): boolean =>
  isRecord(event.payload) && event.payload.turnState === "ended"

const goalTurnEndAfter = async (state: RetryState): Promise<RuntimeEvent> => {
  const ended = Promise.withResolvers<RuntimeEvent>()
  const extension = makeGrokBuildExtension({
    emit: (event) => {
      if (isTurnEnd(event)) ended.resolve(event)
    },
    enqueueQuestion: () => new Promise(() => undefined)
  })
  const app = new acp.ClientApp().onRequest<unknown, Record<string, never>>(
    FLUSH_METHOD,
    (params) => params,
    () => ({})
  )
  const agent = new acp.AgentApp().onRequest(
    acp.methods.agent.session.prompt,
    async ({ client }) => {
      await client.notify("_x.ai/session_notification", retryStateNotification(state))
      await client.request(FLUSH_METHOD, {})
      throw new acp.RequestError(-32003, "Rate limited")
    }
  )
  const connection = (extension.configureClientApp?.(app) ?? app).connect(agent)
  connections.push(connection)
  const extended = extension.sdkConnectionCustomization?.extendConnection?.(
    new FailingConnection(() => Promise.resolve()),
    { connection }
  )
  await Effect.runPromise(extended!.setGoal!("s-1", { objective: "Ship the release" }))
  return ended.promise
}

const usageLimitEnd = (stopDetail: string) => ({
  stopDetail,
  stopKind: "usageLimit",
  stopReason: "end_turn"
})

describe("Grok Build turn failures", () => {
  it.each([
    {
      name: "for authentication as needing sign-in",
      state: failed("auth", "401"),
      stop: {
        stopDetail: "Grok Build isn't signed in. Sign in to continue.",
        stopKind: "authRequired",
        stopReason: "end_turn"
      }
    },
    {
      name: "after the free usage ran out as a usage limit",
      state: exhausted(
        "API error (status 429 Too Many Requests): subscription:free-usage-exhausted: You have used all your free usage."
      ),
      stop: usageLimitEnd("You have used all your free usage.")
    },
    {
      name: "after the usage balance ran out as a usage limit",
      state: failed(
        "api",
        "API error (status 402 Payment Required): Grok Build usage balance exhausted"
      ),
      stop: usageLimitEnd("Grok Build usage balance exhausted")
    },
    {
      name: "after the credits ran out as a usage limit",
      state: failed("api", "API error (status 403 Forbidden): You have run out of credits."),
      stop: usageLimitEnd("You have run out of credits.")
    }
  ])("ends a prompt Grok failed $name", async ({ state, stop }) => {
    expect(await promptFailingAfter(state)).toEqual(stop)
  })

  it.each([
    { name: "a transient sign-in failure", state: failed("auth_transient", "401") },
    { name: "no reported failure", state: undefined },
    {
      name: "an ordinary rate limit",
      state: exhausted("API error (status 429 Too Many Requests): slow down")
    },
    {
      name: "exhausted retries that weren't rate limited",
      state: exhausted(
        "subscription:free-usage-exhausted: You have used all your free usage.",
        false
      )
    },
    {
      name: "a forbidden request",
      state: failed("api", "API error (status 403 Forbidden): denied")
    },
    { name: "a server error", state: failed("api", "API error (status 500 Internal Server Error)") }
  ])("keeps failing a prompt after $name", async ({ state }) => {
    await expect(promptFailingAfter(state)).rejects.toMatchObject({ message: "Internal error" })
  })

  it.each([
    {
      name: "after the free usage ran out as a usage limit",
      state: exhausted("subscription:free-usage-exhausted: You have used all your free usage."),
      stop: usageLimitEnd("You have used all your free usage.")
    },
    {
      name: "for another reason as cancelled",
      state: exhausted("API error (status 429 Too Many Requests): slow down"),
      stop: { stopReason: "cancelled" }
    }
  ])("ends a goal turn Grok failed $name", async ({ state, stop }) => {
    const event = await goalTurnEndAfter(state)
    expect(event.payload).toEqual({
      ...stop,
      initiatedBy: "user",
      turnId: expect.any(String),
      turnState: "ended"
    })
  })
})
