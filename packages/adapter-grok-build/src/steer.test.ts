import * as acp from "@agentclientprotocol/sdk"
import type { AcpAgentConnection } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { makeGrokBuildExtension } from "./extension.js"

const FLUSH_METHOD = "_codevisor/test_flush"
const NOTIFY_METHOD = "_codevisor/test_notify"
const connections: Array<{ readonly close: () => void }> = []

afterEach(() => {
  for (const connection of connections.splice(0)) connection.close()
})

class HeldConnection implements AcpAgentConnection {
  readonly started = Promise.withResolvers<void>()
  readonly finish = Promise.withResolvers<{ stopReason: string }>()

  createSession(cwd: string) {
    return Effect.succeed({ configOptions: [], cwd, sessionId: "s-1" })
  }

  loadSession(sessionId: string) {
    return Effect.succeed({ configOptions: [], sessionId })
  }

  prompt() {
    return Effect.promise(() => {
      this.started.resolve()
      return this.finish.promise
    })
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

type Notification = readonly [string, unknown]

const running = (runningPromptId?: string) =>
  [
    "_x.ai/queue/changed",
    {
      sessionId: "s-1",
      entries: [],
      ...(runningPromptId === undefined ? {} : { runningPromptId })
    }
  ] as const

const completed = (prompt_id: string) =>
  [
    "_x.ai/session_notification",
    {
      sessionId: "s-1",
      update: { sessionUpdate: "turn_completed", prompt_id, stop_reason: "end_turn" }
    }
  ] as const

const steeringSetup = (interject: () => unknown = () => ({ result: { status: "queued" } })) => {
  const events: Array<RuntimeEvent> = []
  const interjections: Array<unknown> = []
  const goalPrompted = Promise.withResolvers<void>()
  const outgoing: Array<Notification> = []
  const extension = makeGrokBuildExtension({
    emit: (event) => void events.push(event),
    enqueueQuestion: () => new Promise(() => undefined)
  })
  const app = new acp.ClientApp().onRequest<unknown, Record<string, never>>(
    FLUSH_METHOD,
    (params) => params,
    () => ({})
  )
  const agent = new acp.AgentApp()
    .onRequest(acp.methods.agent.session.prompt, () => {
      goalPrompted.resolve()
      return new Promise<acp.PromptResponse>(() => undefined)
    })
    .onRequest<unknown, unknown>(
      "_x.ai/interject",
      (params) => params,
      ({ params }) => {
        interjections.push(params)
        return interject()
      }
    )
    .onRequest<unknown, Record<string, never>>(
      NOTIFY_METHOD,
      (params) => params,
      async ({ client }) => {
        for (const [method, notification] of outgoing.splice(0)) {
          await client.notify(method, notification)
        }
        await client.request(FLUSH_METHOD, {})
        return {}
      }
    )
  const connection = (extension.configureClientApp?.(app) ?? app).connect(agent)
  connections.push(connection)
  const base = new HeldConnection()
  const extended = extension.sdkConnectionCustomization?.extendConnection?.(base, { connection })
  if (extended?.steer === undefined) throw new Error("Grok connections steer")
  const steer = extended.steer
  return {
    base,
    events,
    extended,
    goalPrompted,
    interjections,
    notify: (...notifications: ReadonlyArray<Notification>) => {
      outgoing.push(...notifications)
      return connection.agent.request(NOTIFY_METHOD, {})
    },
    steer: (text: string) => Effect.runPromise(steer("s-1", text))
  }
}

const turnPayloads = (events: ReadonlyArray<RuntimeEvent>) =>
  events.flatMap((event) =>
    isRecord(event.payload) && "turnState" in event.payload ? [event.payload] : []
  )

describe("Grok Build steering", () => {
  it("interjects into a running prompt until it is cancelled or ends", async () => {
    const { base, extended, interjections, steer } = steeringSetup()
    await expect(steer("too early")).resolves.toBe(false)
    const prompt = Effect.runPromise(extended.prompt("s-1", "do work"))
    await base.started.promise
    await expect(steer("also check the tests")).resolves.toBe(true)
    expect(interjections).toEqual([
      { sessionId: "s-1", text: "also check the tests", interjectionId: expect.any(String) }
    ])
    await Effect.runPromise(extended.cancel("s-1"))
    await expect(steer("after cancel")).resolves.toBe(false)
    base.finish.resolve({ stopReason: "cancelled" })
    await prompt
    await expect(steer("after")).resolves.toBe(false)
    expect(interjections).toHaveLength(1)
  })

  it("interjects into a running goal turn", async () => {
    const { extended, goalPrompted, interjections, steer } = steeringSetup()
    await Effect.runPromise(extended.setGoal!("s-1", { objective: "Ship the release" }))
    await goalPrompted.promise
    await expect(steer("prefer the small fix")).resolves.toBe(true)
    expect(interjections).toHaveLength(1)
  })

  it.each([
    { name: "anything but queued", reply: () => ({ result: { status: "dropped" } }) },
    {
      name: "an error",
      reply: () => {
        throw acp.RequestError.invalidParams(undefined, "session not found: s-1")
      }
    }
  ])("declines a steer Grok answers with $name", async ({ reply }) => {
    const { base, extended, steer } = steeringSetup(reply)
    void Effect.runPromise(extended.prompt("s-1", "do work"))
    await base.started.promise
    await expect(steer("also this")).resolves.toBe(false)
  })

  it("wraps the turn Grok starts for a steer that missed the running turn", async () => {
    const { events, notify } = steeringSetup()
    const fallback = "interject-fallback-1"
    await notify(running("user-prompt"), running(fallback), running(fallback), running())
    expect(turnPayloads(events)).toEqual([
      { initiatedBy: "user", turnId: fallback, turnState: "started" }
    ])
    await notify(completed("user-prompt"), completed(fallback), completed(fallback))
    expect(turnPayloads(events)).toEqual([
      { initiatedBy: "user", turnId: fallback, turnState: "started" },
      { initiatedBy: "user", stopReason: "end_turn", turnId: fallback, turnState: "ended" }
    ])
  })
})
