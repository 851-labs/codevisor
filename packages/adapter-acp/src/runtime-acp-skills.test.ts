import { skillsUpdateEvent, type RuntimeEmit } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("@codevisor/agent-runtime skills", () => {
  it("keeps a session's metadata on its latest skills update", async () => {
    let emit: RuntimeEmit | undefined
    const handle = {
      cancel: Effect.void,
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const provider = {
      createSession: (_definition: unknown, _cwd: unknown, sessionEmit: RuntimeEmit) =>
        Effect.sync(() => {
          emit = sessionEmit
          return { handle, metadata: { configOptions: [], sessionId: "skills-1" } }
        }),
      id: "claude" as const,
      loadSession: (_definition: unknown, agentSessionId: string) =>
        Effect.succeed({ handle, sessionId: agentSessionId }),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: provider as never }
    })
    await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))
    const skills = { invocationPrefix: "/", skills: [{ invocation: "/review", name: "review" }] }

    await emit?.({
      kind: "session.output",
      payload: { sessionUpdate: "available_skills_update", skills: "malformed" },
      subjectId: "skills-1"
    })
    await emit?.(skillsUpdateEvent("skills-1", skills))

    const loaded = await run(
      runtime.loadAgentSession("claude-code", "skills-1", "/tmp/project", () => undefined)
    )
    expect(loaded.skills).toEqual(skills)
  })
})
