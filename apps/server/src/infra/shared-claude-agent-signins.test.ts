import type { HarnessAuthFlow } from "@codevisor/api"
import { sharedOAuthIdentity, type SharedTokenBundle } from "@codevisor/harness-manager"
import { afterEach, describe, expect, it, vi } from "vitest"

import { run } from "../test-support.js"
import { fleet, native } from "./shared-accounts-test-support.js"

afterEach(() => vi.useRealTimers())

const bobLogin: SharedTokenBundle = {
  ...native("bob"),
  harnessId: "claude-code",
  ownership: "managed",
  refreshToken: "bob-refresh",
  expiresAt: 1
}

const signingInMachine = async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const m = await fleet().machine("a")
  const logins = new Map<string, string>()
  Object.assign(m.auth, {
    beginLogin: async (id: string): Promise<HarnessAuthFlow> => {
      const login = await m.shared.prepareLogin(id)
      logins.set("claude-flow", login)
      return { id: "claude-flow", accountId: login, kind: "pasteCode", url: "https://claude.test" }
    },
    answerLogin: async (flowId: string): Promise<HarnessAuthFlow> => {
      const login = logins.get(flowId)!
      m.setBundle(bobLogin)
      await m.shared.captureLogin(login)
      m.setBundle(undefined)
      return { id: flowId, accountId: login, kind: "complete" }
    },
    cancelLogin: async (flowId: string) => m.shared.loginFailed(logins.get(flowId)!),
    removeAccount: async (id: string) => run(m.db.removeHarnessAccount(id))
  })
  return m
}

const claudeAccountIds = async (m: Awaited<ReturnType<typeof signingInMachine>>) =>
  ((await m.shared.accounts("claude-code")) ?? []).map((account) => account.id)

describe("signing in to Claude from an OpenCode profile", () => {
  it("adds one Claude account and links the profile to it", async () => {
    const m = await signingInMachine()
    const agent = m.shared.providers.claudeAgent!

    const flow = await agent.begin("default", { account: "new" })
    expect(await agent.answer(flow.id, "code")).toMatchObject({ state: "complete" })

    const bob = sharedOAuthIdentity(bobLogin)
    expect(await claudeAccountIds(m)).toEqual([bob])
    expect(await m.shared.providers.configured("opencode", "default")).toEqual(["claude-agent"])
  })

  it("leaves no Claude accounts behind when the sign-in is cancelled", async () => {
    const m = await signingInMachine()
    const agent = m.shared.providers.claudeAgent!

    const flow = await agent.begin("default", { account: "new" })
    await agent.cancel(flow.id)

    expect(await claudeAccountIds(m)).toEqual([])
    expect(await m.shared.providers.configured("opencode", "default")).toEqual([])
  })
})
