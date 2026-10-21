import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import type { AcpConnector } from "./connection.js"
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

  it("steers ACP sessions whose connection can steer", async () => {
    const fake = makeConnector()
    const steered: Array<readonly [string, unknown]> = []
    const connector: AcpConnector = {
      connect: (request, emit) =>
        fake.connect(request, emit).pipe(
          Effect.map((connection) =>
            Object.assign(connection, {
              steer: (sessionId: string, input: unknown) =>
                Effect.sync(() => {
                  steered.push([sessionId, input])
                  return true
                })
            })
          )
        )
    }
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", () => undefined)
    )
    await expect(run(runtime.steer!(sessionId, "also check the tests"))).resolves.toBe(true)
    expect(steered).toEqual([[expect.any(String), "also check the tests"]])
  })
})
