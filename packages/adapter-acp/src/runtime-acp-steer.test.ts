import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

describe("@codevisor/agent-runtime steer", () => {
  it("steers through handles that support it, declines everywhere else, and says which can", async () => {
    const steered: Array<unknown> = []
    const handle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void,
      steer: (input: unknown) =>
        Effect.sync(() => {
          steered.push(input)
          return true
        })
    }
    const custom = {
      createSession: () =>
        Effect.succeed({
          handle,
          metadata: {
            configOptions: [],
            modes: {
              availableModes: [{ id: "default", name: "Default" }],
              currentModeId: "default"
            },
            sessionId: "steerable-1"
          }
        }),
      id: "claude" as const,
      loadSession: (_definition: unknown, agentSessionId: string) =>
        Effect.succeed({ handle, sessionId: agentSessionId }),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      connector: makeConnector(),
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom }
    })
    const steerable = await run(
      runtime.createAgentSession("claude-code", "/tmp/project", () => undefined)
    )
    const plain = await run(runtime.createAgentSession("gemini", "/tmp/project", () => undefined))
    const { steer } = runtime
    if (steer === undefined) throw new Error("The runtime does not expose steer")

    await expect(run(steer(steerable, "also check the tests"))).resolves.toBe(true)
    await expect(run(steer(plain, "ignored"))).resolves.toBe(false)
    await expect(run(steer("missing", "ignored"))).resolves.toBe(false)
    expect(steered).toEqual(["also check the tests"])
    const load = (harnessId: string, sessionId: string) =>
      run(runtime.loadAgentSession(harnessId, sessionId, "/tmp/project", () => undefined))
    expect((await load("claude-code", steerable)).supportsSteering).toBe(true)
    expect((await load("gemini", plain)).supportsSteering).toBe(false)
  })
})
