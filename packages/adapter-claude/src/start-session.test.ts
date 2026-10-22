import type { HarnessAccountContext, RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it, vi } from "vitest"

import { makeClaudeProvider } from "./provider.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  makeProvider,
  run
} from "./test-support.js"

const inheritedEnv = {
  ANTHROPIC_API_KEY: "inherited-key",
  CLAUDE_CODE_OAUTH_TOKEN: "inherited-token",
  HOME: "/home/user",
  PATH: "/bin",
  UNSET: undefined
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

      expect(claudeEnv).toStrictEqual(env)
    }
  )

  it("reports a stream failure between turns as a session error", async () => {
    const fake = new FakeQuery()
    const failed = Promise.withResolvers<RuntimeEvent>()
    const emit = async (event: RuntimeEvent): Promise<void> => {
      if (event.kind === "session.error") failed.resolve(event)
    }
    const created = run(makeProvider(fake).createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const session = await created

    fake.fail("socket closed")

    expect(await failed.promise).toEqual({
      kind: "session.error",
      payload: { message: "socket closed" },
      subjectId: session.metadata.sessionId
    })
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
