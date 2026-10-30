import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

const sink = (): void => undefined

describe("resuming ACP sessions after a harness update", () => {
  it.each([
    { canLoadSession: undefined, resumable: true },
    { canLoadSession: true, resumable: true },
    { canLoadSession: false, resumable: false }
  ])(
    "reports a loaded session as resumable=$resumable when the agent's loadSession is $canLoadSession",
    async ({ canLoadSession, resumable }) => {
      const connector = makeConnector(canLoadSession === undefined ? {} : { canLoadSession })
      const runtime = makeAcpAgentRuntime({
        connector,
        env: { PATH: "/bin" },
        executableExists: (name) => name === "gemini",
        locateExecutable: (name) => `/bin/${name}`
      })

      const sessionId = await run(runtime.createAgentSession("gemini", "/tmp/project", sink))

      expect(runtime.loadedAgentSessions()).toEqual([{ harnessId: "gemini", resumable, sessionId }])
    }
  )

  it("starts a fresh agent process for a session whose process exited", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(runtime.createAgentSession("gemini", "/tmp/project", sink))
    const load = () => run(runtime.loadAgentSession("gemini", sessionId, "/tmp/project", sink))

    await load()
    expect(connector.connections).toHaveLength(1)

    connector.connections[0]!.processExited = true
    await load()

    expect(connector.connections).toHaveLength(2)
    expect(connector.connections[0]!.closeCount).toBe(1)
    expect(connector.connections[1]!.loaded).toEqual([[sessionId, "/tmp/project"]])
  })
})
