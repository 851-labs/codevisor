import * as acp from "@agentclientprotocol/sdk"
import { Effect, Result } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import {
  advertisesSteering,
  sdkConnection,
  STEERING_METHOD,
  type AcpSdkConnectionCustomization
} from "./sdk-connection.js"

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

const promptingAgent = (respond: () => Promise<acp.PromptResponse>) =>
  acp.client({ name: "test" }).connect(
    acp
      .agent({ name: "fake-agent" })
      .onRequest(acp.methods.agent.session.new, () => newSession)
      .onRequest(acp.methods.agent.session.prompt, respond)
  )

const rejectingWith = (error: acp.RequestError) => () => Promise.reject(error)

const promptRejectedWith = async (
  error: acp.RequestError,
  customization?: AcpSdkConnectionCustomization
) => {
  const connection = sdkConnection(
    promptingAgent(rejectingWith(error)),
    () => "",
    customization === undefined ? {} : { customization }
  )
  try {
    return await Effect.runPromise(Effect.result(connection.prompt("s-1", "hi")))
  } finally {
    await Effect.runPromise(connection.close)
  }
}

const now = new Date("2026-10-20T12:00:00.000Z")

const later = (milliseconds: number): string => new Date(now.getTime() + milliseconds).toISOString()

const usageLimitEnd = (stopDetail: string, resetsAt?: string) => ({
  stopDetail,
  stopKind: "usageLimit",
  stopReason: "end_turn",
  ...(resetsAt === undefined ? {} : { resetsAt })
})

describe("sdkConnection.prompt", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(now)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("ends the turn as needing sign-in when the agent rejects the prompt for authentication", async () => {
    const result = await promptRejectedWith(
      acp.RequestError.authRequired({}, "provider authentication required")
    )
    expect(result).toEqual(Result.succeed({ stopKind: "authRequired", stopReason: "end_turn" }))
  })

  it.each([
    {
      name: "Gemini's daily quota",
      error: new acp.RequestError(429, "You have exhausted your daily quota on this model."),
      stop: usageLimitEnd("You have exhausted your daily quota on this model.")
    },
    {
      name: "Gemini's capacity quota, without its trailing tip",
      error: new acp.RequestError(
        429,
        "You have exhausted your capacity on this model. Your quota will reset after 19h14m47s.\n\n💡 Tip: Switch to a different model with /model."
      ),
      stop: usageLimitEnd(
        "You have exhausted your capacity on this model. Your quota will reset after 19h14m47s.",
        later((19 * 3600 + 14 * 60 + 47) * 1000)
      )
    },
    {
      name: "a Gemini API key with no quota left",
      error: new acp.RequestError(
        429,
        "Quota exceeded for metric: generate_content_free_tier_requests, limit: 0\nPlease retry in 59.9s."
      ),
      stop: usageLimitEnd(
        "Quota exceeded for metric: generate_content_free_tier_requests, limit: 0\nPlease retry in 59.9s.",
        later(59_900)
      )
    },
    {
      name: "Codex's usage limit",
      error: acp.RequestError.internalError(
        { codexErrorInfo: "usageLimitExceeded" },
        "You've hit your usage limit. Upgrade to Pro, or try again in ~142 min."
      ),
      stop: usageLimitEnd(
        "You've hit your usage limit. Upgrade to Pro, or try again in ~142 min.",
        later(142 * 60_000)
      )
    },
    {
      name: "Claude's usage limit",
      error: acp.RequestError.internalError(
        { errorKind: "rate_limit" },
        "You've hit your limit · resets 3pm (America/New_York)"
      ),
      stop: usageLimitEnd("You've hit your limit · resets 3pm (America/New_York)")
    },
    {
      name: "Claude running out of credits",
      error: acp.RequestError.internalError(
        { errorKind: "billing_error" },
        "Your org is out of usage · add funds to continue"
      ),
      stop: usageLimitEnd("Your org is out of usage · add funds to continue")
    },
    {
      name: "Claude's billing error without limit copy",
      error: acp.RequestError.internalError({ errorKind: "billing_error" }, "Billing problem"),
      stop: usageLimitEnd("Billing problem")
    },
    {
      name: "a provider's insufficient balance",
      error: new acp.RequestError(402, "Insufficient Balance"),
      stop: usageLimitEnd("Insufficient Balance")
    }
  ])("ends the turn at the account's usage limit for $name", async ({ error, stop }) => {
    expect(await promptRejectedWith(error)).toEqual(Result.succeed(stop))
  })

  it("lets a harness recognize its own usage-limit failures", async () => {
    const result = await promptRejectedWith(
      acp.RequestError.internalError(undefined, "The usage limit has been reached"),
      { isUsageLimitFailure: (failure) => failure.message.endsWith("usage limit has been reached") }
    )
    expect(result).toEqual(Result.succeed(usageLimitEnd("The usage limit has been reached")))
  })

  it.each([
    {
      name: "Claude's organization block",
      error: acp.RequestError.internalError(
        { errorKind: "oauth_org_not_allowed" },
        "Your organization has disabled Claude subscription access for Claude Code"
      ),
      stopDetail: "Your organization has disabled Claude subscription access for Claude Code"
    },
    {
      name: "an HTTP 403 in the error data",
      error: acp.RequestError.internalError(
        { codexErrorInfo: { responseStreamConnectionFailed: {} }, httpStatusCode: 403 },
        "Request blocked"
      ),
      stopDetail: "Request blocked"
    },
    {
      name: "a 403 error code",
      error: new acp.RequestError(403, "The caller does not have permission"),
      stopDetail: "The caller does not have permission"
    },
    {
      name: "a region block",
      error: acp.RequestError.internalError(
        undefined,
        "User location is not supported in your region for the API use."
      ),
      stopDetail: "User location is not supported in your region for the API use."
    }
  ])("ends the turn as forbidden for $name", async ({ error, stopDetail }) => {
    expect(await promptRejectedWith(error)).toEqual(
      Result.succeed({ stopDetail, stopKind: "forbidden", stopReason: "end_turn" })
    )
  })

  it.each([
    {
      name: "a plain rate limit",
      error: new acp.RequestError(429, "Rate limit exceeded. Try again later.")
    },
    {
      name: "a model with no capacity",
      error: new acp.RequestError(503, "No capacity available for model gemini-3-pro-preview")
    },
    {
      name: "Claude's transient rate limit",
      error: acp.RequestError.internalError({ errorKind: "rate_limit" }, "API Error: 429")
    },
    {
      name: "another agent error",
      error: acp.RequestError.internalError({ errorName: "provider.no-route" }, "Model unavailable")
    },
    {
      name: "an agent error without details",
      error: acp.RequestError.internalError(undefined, "limit: 0")
    }
  ])("still fails the prompt for $name", async ({ error }) => {
    expect(await promptRejectedWith(error)).toMatchObject(
      Result.fail({ operation: "prompt", message: error.message })
    )
  })

  it("still fails the prompt when the connection closes mid-turn", async () => {
    const connection = sdkConnection(
      promptingAgent(() => new Promise(() => undefined)),
      () => ""
    )
    const prompt = Effect.runPromise(connection.prompt("s-1", "hi"))
    await Effect.runPromise(connection.close)
    await expect(prompt).rejects.toMatchObject({ operation: "prompt" })
  })
})

const steeringAgent = (outcome: () => unknown) => {
  const prompted = Promise.withResolvers<void>()
  const finish = Promise.withResolvers<acp.PromptResponse>()
  const steers: Array<unknown> = []
  const agent = acp
    .agent({ name: "fake-agent" })
    .onRequest(acp.methods.agent.session.prompt, () => {
      prompted.resolve()
      return finish.promise
    })
    .onRequest<unknown, unknown>(
      STEERING_METHOD,
      (params) => params,
      ({ params }) => {
        steers.push(params)
        return outcome()
      }
    )
  return { connection: acp.client({ name: "test" }).connect(agent), finish, prompted, steers }
}

describe("sdkConnection.steer", () => {
  it("reads the steering advertisement from the top-level initialize _meta", () => {
    expect(advertisesSteering({ _meta: { steering: { supported: true } } })).toBe(true)
    expect(advertisesSteering({ _meta: { steering: { supported: "yes" } } })).toBe(false)
    expect(advertisesSteering({ _meta: { steering: true } })).toBe(false)
    expect(advertisesSteering({ _meta: null })).toBe(false)
    expect(advertisesSteering(undefined)).toBe(false)
  })

  it("carries whether the agent can load sessions", async () => {
    const agent = steeringAgent(() => ({ outcome: "injected" }))
    const unknown = sdkConnection(agent.connection, () => "")
    const cannotLoad = sdkConnection(agent.connection, () => "", { canLoadSession: false })
    expect(unknown.canLoadSession).toBeUndefined()
    expect(cannotLoad.canLoadSession).toBe(false)
    await Effect.runPromise(unknown.close)
  })

  it("only steers agents that advertise it", async () => {
    const agent = steeringAgent(() => ({ outcome: "injected" }))
    const connection = sdkConnection(agent.connection, () => "")
    expect(connection.steer).toBeUndefined()
    await Effect.runPromise(connection.close)
  })

  it("injects into a running prompt and declines when idle or when the agent won't take it", async () => {
    const outcomes: Array<() => unknown> = [
      () => ({ outcome: "injected" }),
      () => ({ outcome: "promptRequired", reason: "noRunningTurn" }),
      () => ({ outcome: "startedNewTurn" }),
      () => ({ outcome: "failed" }),
      () => {
        throw acp.RequestError.internalError(undefined, "Session ended")
      }
    ]
    const agent = steeringAgent(() => outcomes.shift()!())
    const connection = sdkConnection(agent.connection, () => "", {
      promptCapabilities: {},
      steering: true
    })
    const steer = (text: string) => Effect.runPromise(connection.steer!("s-1", text))

    await expect(steer("too early")).resolves.toBe(false)
    expect(agent.steers).toEqual([])
    const prompt = Effect.runPromise(connection.prompt("s-1", "do work"))
    await agent.prompted.promise
    await expect(steer("also this")).resolves.toBe(true)
    expect(agent.steers).toEqual([
      {
        sessionId: "s-1",
        prompt: [{ text: "also this", type: "text" }],
        _meta: { steering: { idleBehavior: "promptRequired" } }
      }
    ])
    await expect(steer("turn just ended")).resolves.toBe(false)
    await expect(steer("detached")).resolves.toBe(true)
    await expect(steer("failed")).resolves.toBe(false)
    await expect(steer("rejected")).resolves.toBe(false)
    agent.finish.resolve({ stopReason: "end_turn" })
    await expect(prompt).resolves.toEqual({ stopReason: "end_turn" })
    await expect(steer("after")).resolves.toBe(false)
    expect(agent.steers).toHaveLength(5)
    await Effect.runPromise(connection.close)
  })
})
