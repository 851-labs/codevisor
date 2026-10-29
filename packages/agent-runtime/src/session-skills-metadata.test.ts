import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAgentRuntime } from "./index.js"
import { skillsUpdateEvent } from "./session-skills.js"
import type { AgentProvider, AgentSessionHandle, RuntimeEmit } from "./types.js"

const handle: AgentSessionHandle = {
  cancel: Effect.succeed({ runtimeState: "reusable" }),
  close: Effect.void,
  prompt: () => Effect.succeed({ stopReason: "end_turn" }),
  setConfigOption: () => Effect.succeed([]),
  setMode: () => Effect.void
}

describe("session skills metadata", () => {
  it("keeps the native commands, if any, from a session's latest skills update", async () => {
    let emit: RuntimeEmit | undefined
    const provider: AgentProvider = {
      id: "claude",
      readiness: () => ({ state: "ready" }),
      createSession: (_definition, _cwd, sessionEmit) =>
        Effect.sync(() => {
          emit = sessionEmit
          return { handle, metadata: { configOptions: [], sessionId: "agent-1" } }
        }),
      loadSession: (_definition, sessionId) => Effect.succeed({ handle, sessionId })
    }
    const runtime = makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: provider } })
    await Effect.runPromise(runtime.createAgentSession("claude-code", "/tmp/skills", () => {}))
    const load = () =>
      Effect.runPromise(runtime.loadAgentSession("claude-code", "agent-1", "/tmp/skills", () => {}))
    const plain = { invocationPrefix: "/", skills: [] }
    const compacting = { ...plain, commands: ["compact"] }

    await emit?.(skillsUpdateEvent("agent-1", plain))
    const before = await load()
    await emit?.(skillsUpdateEvent("agent-1", compacting))
    const after = await load()

    expect([before.skills, after.skills]).toEqual([plain, compacting])
  })
})
