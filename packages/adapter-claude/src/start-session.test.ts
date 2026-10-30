import type { HarnessAccountContext, RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it, vi } from "vitest"

import { makeClaudeProvider } from "./provider.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  run,
  sdkMessage,
  systemMessage
} from "./test-support.js"

const inheritedEnv = {
  ANTHROPIC_API_KEY: "inherited-key",
  CLAUDE_CODE_OAUTH_TOKEN: "inherited-token",
  HOME: "/home/user",
  PATH: "/bin",
  UNSET: undefined
}

const startupFailure = (error: string) =>
  sdkMessage({
    duration_ms: 0,
    errors: [error],
    is_error: true,
    num_turns: 0,
    session_id: "lost-session",
    stop_reason: null,
    subtype: "error_during_execution",
    type: "result"
  })

const loadFailingAtStartup = async (error: string) => {
  const fake = new FakeQuery()
  fake.initializationFailure = new Error("Query closed before response received")
  const events: Array<RuntimeEvent> = []
  const loading = run(
    makeProvider(fake).loadSession(definition, "lost-session", "/tmp", async (event) => {
      events.push(event)
    })
  )
  fake.push(startupFailure(error))
  fake.finish()
  return { events, fake, loading }
}

const claudeEnvFor = async (account: HarnessAccountContext): Promise<unknown> => {
  const fake = new FakeQuery()
  const provider = makeClaudeProvider(
    { ...environment, envFor: async () => inheritedEnv },
    {
      checkVersion: async () => "2.1.0",
      queryFn: (input) => {
        fake.options = input.options
        return fake
      }
    }
  )
  const created = run(provider.createSession(definition, "/tmp", async () => {}, account))
  fake.push(initMessage())
  await created
  return fake.options?.env
}

describe("Claude session start", () => {
  it.each([
    {
      account: { id: "own", profileKind: "default" as const, env: { EXTRA: "1" } },
      env: {
        ANTHROPIC_API_KEY: "inherited-key",
        CLAUDE_CODE_OAUTH_TOKEN: "inherited-token",
        EXTRA: "1",
        HOME: "/home/user",
        PATH: "/bin"
      }
    },
    {
      account: {
        id: "shared",
        profileKind: "managed" as const,
        env: { CLAUDE_CODE_OAUTH_TOKEN: "account-token" },
        unsetEnv: ["HOME"]
      },
      env: { CLAUDE_CODE_OAUTH_TOKEN: "account-token", PATH: "/bin" }
    }
  ])(
    "runs Claude with the $account.profileKind account's environment",
    async ({ account, env }) => {
      const claudeEnv = await claudeEnvFor(account)

      expect(claudeEnv).toStrictEqual({ ...env, CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: "1" })
    }
  )

  it("reports Claude idle when its process stops while running", async () => {
    const fake = new FakeQuery()
    const events: Array<RuntimeEvent> = []
    const created = run(
      makeProvider(fake).createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    await created

    fake.push(systemMessage("session_state_changed", { state: "running" }))
    fake.fail("killed")
    await fake.drain()

    const states = events.map(payloadOf).filter((payload) => payload.runtimeState !== undefined)
    expect(states).toEqual([{ runtimeState: "running" }, { runtimeState: "idle" }])
  })

  it("fails to load a conversation Claude can't find, without opening a turn", async () => {
    const { events, fake, loading } = await loadFailingAtStartup(
      "No conversation found with session ID: lost-session"
    )

    await expect(loading).rejects.toMatchObject({
      conversationMissing: true,
      message: "Claude Code couldn't find this chat's saved conversation."
    })
    expect(events.filter((event) => payloadOf(event).turnState !== undefined)).toEqual([])
    expect(fake.options?.abortController?.signal.aborted).toBe(true)
  })

  it("fails to load with Claude's own words when it stops at startup for another reason", async () => {
    const { loading } = await loadFailingAtStartup("Invalid settings file")

    await expect(loading).rejects.toMatchObject({ message: "Invalid settings file" })
    await expect(loading).rejects.not.toHaveProperty("conversationMissing")
  })

  it("hands an idle Claude that exited back to the runtime, logging why without its secrets", async () => {
    const fake = new FakeQuery()
    const events: Array<RuntimeEvent> = []
    const created = run(
      makeProvider(fake).createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    const session = await created
    const logged = Promise.withResolvers<string>()
    const log = vi
      .spyOn(console, "error")
      .mockImplementation((line: string) => logged.resolve(line))
    try {
      expect(session.handle.exited?.()).toBe(false)
      fake.fail(
        new Error(
          "Claude Code process terminated by signal SIGTERM. stderr: retrying with sk-ant-oat01-secret"
        )
      )

      expect(JSON.parse(await logged.promise)).toEqual({
        event: "claude_process_ended",
        sessionId: session.metadata.sessionId,
        turnActive: false,
        failure:
          "Claude Code process terminated by signal SIGTERM. stderr: retrying with sk-ant-<redacted>"
      })
      expect(session.handle.exited?.()).toBe(true)
      expect(events.filter((event) => event.kind === "session.error")).toEqual([])
      await expect(run(session.handle.prompt("hello"))).rejects.toThrow(
        "Claude Code stopped unexpectedly."
      )
    } finally {
      log.mockRestore()
    }
  })

  it("starts without a model picker when Claude cannot list its models", async () => {
    const fake = new FakeQuery()
    vi.spyOn(fake, "supportedModels").mockImplementation(() => {
      throw new Error("model listing is unsupported")
    })

    const created = run(makeProvider(fake).createSession(definition, "/tmp", async () => {}))
    fake.push(initMessage())
    const session = await created

    expect(session.metadata.configOptions.map((option) => option.id)).not.toContain("model")
  })
})
