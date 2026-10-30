import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAgentRuntime } from "./index.js"
import type { AgentProvider, AgentSessionHandle } from "./types.js"

const baseHandle: AgentSessionHandle = {
  prompt: () => Effect.succeed({ stopReason: "end_turn" }),
  cancel: Effect.succeed({ runtimeState: "reusable" }),
  setMode: () => Effect.void,
  setConfigOption: () => Effect.succeed([]),
  close: Effect.void
}

const loadedRuntime = async (handle: AgentSessionHandle) => {
  const provider: AgentProvider = {
    id: "claude",
    readiness: () => ({ state: "ready" }),
    createSession: () =>
      Effect.succeed({ handle, metadata: { sessionId: "agent-1", configOptions: [] } }),
    loadSession: () => Effect.succeed({ handle, sessionId: "agent-1" })
  }
  const runtime = makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: provider } })
  await Effect.runPromise(runtime.loadAgentSession("claude-code", "agent-1", "/tmp", () => {}))
  return runtime
}

describe("background task operations", () => {
  it("stop a task and read its output through the harness", async () => {
    const stopped: Array<string> = []
    const runtime = await loadedRuntime({
      ...baseHandle,
      stopTask: (taskId) => Effect.sync(() => void stopped.push(taskId)),
      readTaskOutput: (taskId, lineLimit) => Effect.succeed([`${taskId}:${lineLimit}`])
    })

    expect(await Effect.runPromise(runtime.stopTask("agent-1", "bg-1"))).toBe(true)
    expect(stopped).toEqual(["bg-1"])
    expect(await Effect.runPromise(runtime.readTaskOutput("agent-1", "bg-1", 50))).toEqual([
      "bg-1:50"
    ])
  })

  it("report a harness without task controls as unable to stop or read output", async () => {
    const runtime = await loadedRuntime(baseHandle)

    expect(await Effect.runPromise(runtime.stopTask("agent-1", "bg-1"))).toBe(false)
    expect(await Effect.runPromise(runtime.readTaskOutput("agent-1", "bg-1", 50))).toBeUndefined()
  })
})
