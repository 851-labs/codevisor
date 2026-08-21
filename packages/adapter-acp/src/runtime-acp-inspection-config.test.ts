import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("@codevisor/agent-runtime inspection configuration", () => {
  it("preserves settings when selections are unchanged, invalid, or rejected", async () => {
    let closeCount = 0
    const applied: Array<readonly [string, string]> = []
    const configOptions = [
      {
        category: "model",
        currentValue: "default",
        id: "model",
        name: "Model",
        options: [
          {
            group: "recommended",
            name: "Recommended",
            options: [
              { name: "Default", value: "default" },
              { name: "Pro", value: "pro" }
            ]
          }
        ]
      },
      {
        category: "thought_level",
        currentValue: "low",
        id: "reasoning",
        name: "Reasoning",
        options: [
          { name: "Low", value: "low" },
          { name: "High", value: "high" }
        ]
      }
    ]
    const handle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.sync(() => {
        closeCount += 1
      }),
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: (configId: string, value: string) => {
        applied.push([configId, value])
        return Effect.die("selection rejected")
      },
      setMode: () => Effect.void
    }
    const custom = {
      createSession: () =>
        Effect.succeed({
          handle,
          metadata: { configOptions, sessionId: "inspection" }
        }),
      id: "claude" as const,
      loadSession: () => Effect.die("unused"),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })

    const inspected = await run(
      runtime.inspectHarness("claude-code", "/tmp/project", undefined, {
        reasoning: "low",
        model: "pro",
        missing: "value"
      })
    )

    expect(applied).toEqual([["model", "pro"]])
    expect(inspected.configOptions).toEqual(configOptions)
    expect(closeCount).toBe(1)
  })
})
