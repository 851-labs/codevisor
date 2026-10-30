import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAgentRuntime } from "./index.js"
import type { AgentProvider, AgentSessionHandle } from "./types.js"

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
})
