import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("@codevisor/agent-runtime session context", () => {
  it("reads context from session handles that report it", async () => {
    const context = {
      categories: [{ name: "Messages", tokens: 1200 }],
      maxTokens: 200_000,
      mcpTools: [],
      totalTokens: 1200
    }
    const handle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      readContext: Effect.succeed(context),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: {
        claude: {
          createSession: () =>
            Effect.succeed({
              handle,
              metadata: { configOptions: [], sessionId: "context-1" }
            }),
          id: "claude" as const,
          loadSession: (_definition: unknown, agentSessionId: string) =>
            Effect.succeed({ handle, sessionId: agentSessionId }),
          readiness: () => ({ state: "ready" }) as const
        }
      }
    })
    const sessionId = await run(
      runtime.createAgentSession("claude-code", "/tmp/project", () => undefined)
    )
    await expect(run(runtime.readSessionContext(sessionId))).resolves.toEqual(context)
  })
})
