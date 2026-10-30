import type { HarnessAccount, HarnessAuthFlow, OpenCodeAuthProvider } from "@codevisor/api"
import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it, vi } from "vitest"

import type { SharedAccountStore } from "./shared-account-store.js"
import { makeClaudeAgentLinks } from "./shared-claude-agent-links.js"
import { makeClaudeSignIns } from "./shared-claude-agent-signins.js"
import { makeSharedClaudeAgent, NEW_CLAUDE_ACCOUNT } from "./shared-claude-agent.js"

const claudeAccount = (
  id: string,
  label: string,
  authState: HarnessAccount["authState"] = "authenticated"
): HarnessAccount => ({
  id,
  harnessId: "claude-code",
  profileKind: "managed",
  label,
  authState,
  isActive: false,
  canLogin: true,
  canLogout: true
})

const listed: OpenCodeAuthProvider = {
  id: "claude-agent",
  name: "Claude Agent",
  methods: [
    { id: "claude-login", type: "oauth", label: "Claude account in Codevisor", prompts: [] }
  ]
}

const memoryStore = (): Pick<SharedAccountStore, "entries" | "writeProvider"> => {
  const entries = new Map<string, SyncEntryRecord>()
  return {
    entries: async () => [...entries.values()],
    writeProvider: async (key, value, deleted) => {
      entries.set(key, {
        key,
        value,
        deleted: deleted ?? false,
        timestamp: { wallMs: 0, counter: 0, deviceId: "a" }
      })
    }
  }
}

const setup = (
  options: {
    accounts?: ReadonlyArray<HarnessAccount>
    flow?: HarnessAuthFlow
    claude?: string
  } = {}
) => {
  const auth = {
    accounts: vi.fn(async () => options.accounts ?? [claudeAccount("shared-alice", "alice@test")]),
    accountContext: vi.fn(async (id: string) => ({
      id,
      profileKind: "managed" as const,
      env: { CLAUDE_CONFIG_DIR: `/profiles/${id}`, CLAUDE_CODE_OAUTH_TOKEN: "token" }
    })),
    beginLogin: vi.fn(
      async (): Promise<HarnessAuthFlow> =>
        options.flow ?? {
          id: "claude-flow",
          accountId: "fresh",
          kind: "pasteCode",
          url: "https://claude.test/authorize"
        }
    ),
    answerLogin: vi.fn(async (): Promise<HarnessAuthFlow> => ({
      id: "claude-flow",
      accountId: "fresh",
      kind: "complete"
    })),
    cancelLogin: vi.fn(async () => {}),
    removeAccount: vi.fn(async () => {})
  }
  const placeholders = {
    create: vi.fn(async () => "placeholder"),
    discard: vi.fn(async () => undefined)
  }
  const links = makeClaudeAgentLinks(memoryStore())
  const agent = makeSharedClaudeAgent({
    links,
    signIns: makeClaudeSignIns({
      auth,
      placeholders,
      resolve: async (id) => (id === "placeholder" ? "shared-bob" : id)
    }),
    auth,
    profile: async (id) => `profile-${id}`,
    environment: async () => ({ PATH: "/bin" }),
    locate: (name) => (options.claude === undefined ? `/bin/${name}` : undefined)
  })
  return { agent, auth, links, placeholders }
}

describe("Claude Agent in OpenCode profiles", () => {
  it("offers the signed-in Claude accounts and a way to add one", async () => {
    const { agent } = setup({
      accounts: [
        claudeAccount("shared-alice", "alice@test"),
        claudeAccount("shared-carol", "carol@test", "expired")
      ]
    })

    expect(await agent.provider("opencode-1", listed)).toEqual({
      ...listed,
      methods: [
        {
          id: "claude-login",
          type: "oauth",
          label: "Claude account in Codevisor",
          prompts: [
            {
              type: "select",
              key: "account",
              message: "Account",
              options: [
                { value: "shared-alice", label: "alice@test" },
                { value: NEW_CLAUDE_ACCOUNT, label: "Sign In to Another Account…" }
              ],
              required: true,
              defaultValue: "shared-alice"
            }
          ]
        }
      ]
    })
  })

  it("links the chosen account to the profile and shows it until it is removed", async () => {
    const { agent, links } = setup()

    expect(await agent.begin("opencode-1", { account: "shared-alice" })).toMatchObject({
      accountId: "opencode-1",
      providerId: "claude-agent",
      state: "complete"
    })
    expect(await links.get("profile-opencode-1")).toBe("shared-alice")
    expect(await agent.provider("opencode-1", listed)).toMatchObject({
      credentialType: "oauth",
      accountLabel: "alice@test"
    })

    expect(await agent.unlink("profile-opencode-1")).toBe(true)
    expect(await agent.linked("profile-opencode-1")).toBe(false)
    expect(await agent.unlink("profile-opencode-1")).toBe(false)
  })

  it("refuses an account that isn't signed in", async () => {
    const { agent, links } = setup({
      accounts: [claudeAccount("shared-carol", "carol@test", "expired")]
    })

    await expect(agent.begin("opencode-1", { account: "shared-carol" })).rejects.toThrow(
      "Sign in to this Claude account first."
    )
    expect(await links.get("profile-opencode-1")).toBeUndefined()
  })

  it("signs in a new Claude account with a pasted code and links the account it became", async () => {
    const { agent, auth, links, placeholders } = setup()

    const started = await agent.begin("opencode-1", { account: NEW_CLAUDE_ACCOUNT })
    expect(started).toMatchObject({
      state: "waiting",
      authorization: { url: "https://claude.test/authorize", method: "code" },
      harnessName: "Claude Code"
    })
    expect(auth.beginLogin).toHaveBeenCalledWith("placeholder")

    expect(await agent.answer(started.id, "code-123")).toMatchObject({ state: "complete" })
    expect(auth.answerLogin).toHaveBeenCalledWith("claude-flow", "code-123")
    expect(await links.get("profile-opencode-1")).toBe("shared-bob")
    expect(placeholders.discard).not.toHaveBeenCalled()
    expect(auth.removeAccount).not.toHaveBeenCalled()
  })

  it("drops the half-made account when its sign-in fails or is cancelled", async () => {
    const { agent, auth, links, placeholders } = setup()
    auth.answerLogin.mockRejectedValueOnce(new Error("Invalid code"))

    const failing = await agent.begin("opencode-1", undefined)
    expect(await agent.answer(failing.id, "bad")).toMatchObject({
      state: "error",
      error: "Invalid code"
    })
    expect(placeholders.discard).toHaveBeenCalledWith("placeholder")
    expect(auth.removeAccount).toHaveBeenCalledWith("fresh")
    auth.answerLogin.mockRejectedValueOnce(
      new Error("This sign-in attempt has expired — start again")
    )
    expect(await agent.answer(failing.id, "retry")).toMatchObject({
      state: "error",
      error: "This sign-in attempt has expired — start again"
    })

    const cancelled = await agent.begin("opencode-1", undefined)
    await agent.cancel(cancelled.id)
    expect(auth.cancelLogin).toHaveBeenCalledWith("claude-flow")
    expect(placeholders.discard).toHaveBeenCalledTimes(3)
    expect(auth.removeAccount).toHaveBeenCalledTimes(3)
    expect(agent.flow(cancelled.id)).toBeUndefined()
    expect(await links.get("profile-opencode-1")).toBeUndefined()
  })

  it("won't start a sign-in that can't be finished with a pasted code", async () => {
    const { agent, auth, placeholders } = setup({
      flow: { id: "browser-flow", accountId: "fresh", kind: "browser", url: "https://x.test" }
    })

    await expect(agent.begin("opencode-1", undefined)).rejects.toThrow("Add the account")
    expect(auth.cancelLogin).toHaveBeenCalledWith("browser-flow")
    expect(placeholders.discard).toHaveBeenCalledWith("placeholder")
    expect(auth.removeAccount).toHaveBeenCalledWith("fresh")
  })

  it("launches claude with the linked account's environment when it can", async () => {
    const linked = setup()
    expect(await linked.agent.launch("profile-opencode-1")).toBeUndefined()

    await linked.links.set("profile-opencode-1", "shared-alice")
    expect(await linked.agent.launch("profile-opencode-1")).toEqual({
      claudePath: "/bin/claude",
      env: { CLAUDE_CONFIG_DIR: "/profiles/shared-alice", CLAUDE_CODE_OAUTH_TOKEN: "token" }
    })

    linked.auth.accountContext.mockRejectedValueOnce(new Error("Harness account requires sign-in"))
    expect(await linked.agent.launch("profile-opencode-1")).toBeUndefined()

    const missing = setup({ claude: "missing" })
    await missing.links.set("profile-opencode-1", "shared-alice")
    expect(await missing.agent.launch("profile-opencode-1")).toBeUndefined()
  })
})
