import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import type { AgentRuntimeConfig, ProviderFactory } from "./agent-runtime-types.js"
import { makeAgentRuntime } from "./index.js"
import type { AgentProvider, AgentSessionHandle } from "./types.js"

const idleHandle: AgentSessionHandle = {
  prompt: () => Effect.succeed({ stopReason: "end_turn" }),
  cancel: Effect.succeed({ runtimeState: "reusable" }),
  setMode: () => Effect.void,
  setConfigOption: () => Effect.succeed([]),
  close: Effect.void
}

const launchingHarness = (config: AgentRuntimeConfig) => {
  const launches: Array<NodeJS.ProcessEnv> = []
  const harness: ProviderFactory = (environment): AgentProvider => {
    const launch = (cwd: string) =>
      Effect.promise(async () => {
        launches.push(await environment.envFor(cwd))
        const sessionId = `agent-${launches.length}`
        return { handle: idleHandle, metadata: { sessionId, configOptions: [] }, sessionId }
      })
    return {
      id: "claude",
      readiness: () => ({ state: "ready" }),
      createSession: (_definition, cwd) => launch(cwd),
      loadSession: (_definition, _agentSessionId, cwd) => launch(cwd)
    }
  }
  const runtime = makeAgentRuntime({ ...config, providerFactories: [harness] })
  const start = (cwd: string) =>
    Effect.runPromise(runtime.createAgentSession("claude-code", cwd, () => undefined))
  return { launches, start }
}

describe("the environment a harness is launched with", () => {
  it("is the folder's environment with the launch environment applied at each launch", async () => {
    let display = ":1"
    const { launches, start } = launchingHarness({
      env: { PATH: "/bin" },
      resolveDirectoryEnv: async (directory) => ({ PATH: `${directory}/bin:/bin` }),
      launchEnvironment: (env) => ({ ...env, DISPLAY: display })
    })

    await start("/work")
    display = ":4"
    await start("/work")

    expect(launches).toEqual([
      { PATH: "/work/bin:/bin", DISPLAY: ":1" },
      { PATH: "/work/bin:/bin", DISPLAY: ":4" }
    ])
  })

  it("starts from the machine's environment when folders have none of their own", async () => {
    const { launches, start } = launchingHarness({
      env: { PATH: "/bin" },
      launchEnvironment: (env) => ({ ...env, DISPLAY: ":1" })
    })

    await start("/work")

    expect(launches).toEqual([{ PATH: "/bin", DISPLAY: ":1" }])
  })
})
