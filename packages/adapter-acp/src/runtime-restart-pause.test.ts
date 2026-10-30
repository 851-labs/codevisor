import type { AgentSessionHandle } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, run } from "./test-support.js"

const runtimeWithHandle = (sessionId: string, handle: AgentSessionHandle) =>
  makeAcpAgentRuntime({
    env: { PATH: "/bin" },
    executableExists: () => true,
    locateExecutable: (name) => `/bin/${name}`,
    providers: {
      claude: {
        createSession: () => Effect.succeed({ handle, metadata: { configOptions: [], sessionId } }),
        id: "claude" as const,
        loadSession: () => Effect.die("unused"),
        readiness: () => ({ state: "ready" }) as const
      }
    }
  })

describe("pausing a session for a restart", () => {
  it("pauses for a restart through the handle's own pause and retires it", async () => {
    const sessionId = "restart-pause"
    let closeCount = 0
    let cancelCount = 0
    const handle = {
      cancel: Effect.sync(() => {
        cancelCount += 1
        return { runtimeState: "reusable" as const }
      }),
      pauseForRestart: Effect.succeed({
        runtimeState: "retire" as const,
        resumesInterruptedTurn: true
      }),
      close: Effect.sync(() => {
        closeCount += 1
      }),
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const runtime = runtimeWithHandle(sessionId, handle)
    await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))

    expect(await run(runtime.pauseForRestart!(sessionId))).toEqual({
      runtimeState: "retire",
      resumesInterruptedTurn: true
    })
    expect([cancelCount, closeCount]).toEqual([0, 1])
    expect(runtime.loadedAgentSessionIds()).not.toContain(sessionId)
  })

  it("cancels the turn when a handle has no restart pause", async () => {
    const sessionId = "restart-pause-fallback"
    const handle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const runtime = runtimeWithHandle(sessionId, handle)
    await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))

    expect(await run(runtime.pauseForRestart!(sessionId))).toEqual({ runtimeState: "reusable" })
    expect(runtime.loadedAgentSessionIds()).toContain(sessionId)
  })
})
