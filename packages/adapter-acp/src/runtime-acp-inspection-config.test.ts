import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("@codevisor/agent-runtime inspection configuration", () => {
  it("reports selections that are unoffered or rejected instead of dropping them", async () => {
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
    expect(inspected.unappliedConfigSelections).toEqual({ missing: "value", model: "pro" })
    expect(closeCount).toBe(1)
  })

  it("applies a drifted requested id under the provider's reconciliation", async () => {
    const applied: Array<readonly [string, string]> = []
    const handle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: (configId: string, value: string) =>
        Effect.sync(() => {
          applied.push([configId, value])
          return [fableModelOption(value)]
        }),
      setMode: () => Effect.void
    }
    const custom = {
      createSession: () =>
        Effect.succeed({
          handle,
          metadata: { configOptions: [fableModelOption("")], sessionId: "i" }
        }),
      id: "claude" as const,
      loadSession: () => Effect.die("unused"),
      readiness: () => ({ state: "ready" }) as const,
      reconcileConfigValue: (_option: unknown, value: string) =>
        value === "claude-fable-5[1m]" ? "claude-fable-5-1[1m]" : undefined
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })

    const inspected = await run(
      runtime.inspectHarness("claude-code", "/tmp/project", undefined, {
        model: "claude-fable-5[1m]"
      })
    )

    expect(applied).toEqual([["model", "claude-fable-5-1[1m]"]])
    expect(inspected.configOptions[0]?.currentValue).toBe("claude-fable-5-1[1m]")
    expect(inspected.unappliedConfigSelections).toBeUndefined()
  })

  it("routes saved-value reconciliation to the harness's provider", () => {
    const option = {
      category: "model",
      currentValue: "default",
      id: "model",
      name: "Model",
      options: [
        { name: "Default", value: "default" },
        { name: "Pro", value: "pro" }
      ]
    }
    const custom = {
      createSession: () => Effect.die("unused"),
      id: "claude" as const,
      loadSession: () => Effect.die("unused"),
      readiness: () => ({ state: "ready" }) as const,
      reconcileConfigValue: (candidate: { readonly id: string }, value: string) =>
        candidate.id === "model" && value === "pro-legacy" ? "pro" : undefined
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })

    expect(runtime.reconcileConfigValue("claude-code", option, "pro-legacy")).toBe("pro")
    expect(runtime.reconcileConfigValue("claude-code", option, "gone")).toBeUndefined()
    // A provider without the hook, and an id outside the catalog, both say
    // the value is gone rather than guessing.
    expect(runtime.reconcileConfigValue("codex", option, "pro-legacy")).toBeUndefined()
    expect(runtime.reconcileConfigValue("not-a-harness", option, "pro-legacy")).toBeUndefined()
  })
})

const fableModelOption = (currentValue: string) => ({
  category: "model",
  currentValue,
  id: "model",
  name: "Model",
  options: [
    { name: "Sonnet", value: "sonnet" },
    { name: "Fable", value: "claude-fable-5-1[1m]" }
  ]
})
