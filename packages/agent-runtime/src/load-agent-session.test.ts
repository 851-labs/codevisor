import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAgentRuntime } from "./index.js"
import type {
  AgentProvider,
  AgentSessionHandle,
  HarnessAccountContext,
  RuntimeEmit,
  RuntimeEvent
} from "./types.js"

const handleThatExits = (closed: Array<string>, name: string) => {
  let exited = false
  const handle: AgentSessionHandle = {
    cancel: Effect.succeed({ runtimeState: "reusable" }),
    close: Effect.sync(() => {
      closed.push(name)
    }),
    exited: () => exited,
    prompt: () => Effect.succeed({ stopReason: "end_turn" }),
    setConfigOption: () => Effect.succeed([]),
    setMode: () => Effect.void
  }
  return { handle, exit: () => (exited = true) }
}

describe("loadAgentSession", () => {
  it("replaces a loaded session whose harness process exited, and keeps a live one", async () => {
    const closed: Array<string> = []
    const handles = [handleThatExits(closed, "first"), handleThatExits(closed, "second")]
    let loads = 0
    const provider: AgentProvider = {
      id: "claude",
      readiness: () => ({ state: "ready" }),
      createSession: () => Effect.die("unused"),
      loadSession: (_definition, sessionId) =>
        Effect.sync(() => ({ handle: handles[loads++]!.handle, sessionId }))
    }
    const runtime = makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: provider } })
    const load = () =>
      Effect.runPromise(runtime.loadAgentSession("claude-code", "agent-1", "/tmp/exits", () => {}))

    await load()
    await load()
    expect(loads).toBe(1)

    handles[0]!.exit()
    await load()

    expect(loads).toBe(2)
    expect(closed).toEqual(["first"])
  })

  it("runs a loaded session on one account, names it on usage-limit stops, and moves it when the account changes", async () => {
    const closed: Array<string> = []
    const emits: Array<RuntimeEmit> = []
    const handles = [handleThatExits(closed, "personal"), handleThatExits(closed, "work")]
    const provider: AgentProvider = {
      id: "claude",
      readiness: () => ({ state: "ready" }),
      createSession: () => Effect.die("unused"),
      loadSession: (_definition, sessionId, _cwd, emit) =>
        Effect.sync(() => {
          emits.push(emit)
          return { handle: handles[emits.length - 1]!.handle, sessionId }
        })
    }
    const runtime = makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: provider } })
    const received: Array<RuntimeEvent> = []
    const load = (accountId: string) =>
      Effect.runPromise(
        runtime.loadAgentSession(
          "claude-code",
          "agent-1",
          "/tmp/accounts",
          (event) => {
            received.push(event)
          },
          account(accountId)
        )
      )

    await load("personal")
    await emits[0]!(usageLimitStop)
    await emits[0]!({ ...usageLimitStop, payload: { turnState: "ended", stopReason: "end_turn" } })

    expect(runtime.loadedAgentSessions()).toEqual([
      {
        sessionId: "agent-1",
        harnessId: "claude-code",
        harnessAccountId: "personal",
        resumable: true
      }
    ])
    expect(received.map((event) => event.payload)).toEqual([
      { ...usageLimitPayload, stoppedOnAccountId: "personal" },
      { turnState: "ended", stopReason: "end_turn" }
    ])

    await load("work")

    expect(closed).toEqual(["personal"])
    expect(runtime.loadedAgentSessions()).toMatchObject([{ harnessAccountId: "work" }])
  })
})

const account = (id: string): HarnessAccountContext => ({ id, profileKind: "managed" })

const usageLimitPayload = {
  turnState: "ended",
  stopReason: "end_turn",
  stopKind: "usageLimit",
  stopDetail: "You've hit your limit"
}

const usageLimitStop: RuntimeEvent = {
  kind: "session.updated",
  subjectId: "agent-1",
  payload: usageLimitPayload
}
