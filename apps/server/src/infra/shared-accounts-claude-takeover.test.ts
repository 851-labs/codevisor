import {
  OAuthRefreshRejected,
  SharedCredentialError,
  sharedApiKey,
  sharedOAuthIdentity,
  type SharedTokenBundle
} from "@codevisor/harness-manager"
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { sharedAccountFor } from "./shared-account-store.js"
import { fakeClaudeMachine, fleet, native } from "./shared-accounts-test-support.js"

afterEach(() => vi.useRealTimers())

const machineLogin = (refreshToken = "machine-refresh", accessToken = "machine-access") =>
  ({
    ...native("alice"),
    harnessId: "claude-code",
    ownership: "managed",
    accessToken,
    refreshToken
  }) satisfies SharedTokenBundle
const accountId = sharedOAuthIdentity(machineLogin())
const weekMs = 7 * 24 * 60 * 60_000

const startClock = () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
}

const quietLogs = () => {
  const errors = vi.spyOn(console, "error").mockImplementation(() => {})
  onTestFinished(() => errors.mockRestore())
  return errors
}

const vaultLogin = async (m: Awaited<ReturnType<ReturnType<typeof fleet>["machine"]>>) =>
  m.vault.token((await m.shared.store.get(accountId))!.credential!)

describe("taking over this machine's Claude Code login", () => {
  it("moves the login into Codevisor's vault and signs Claude Code out when Codevisor has none", async () => {
    startClock()
    const logs = quietLogs()
    const m = await fleet().machine("a")
    m.claude.signIn(machineLogin())

    await m.shared.reconcile()
    await m.shared.reconcile()

    expect(m.claude.login()).toBeUndefined()
    expect(m.claude.signOut).toHaveBeenCalledOnce()
    expect(await vaultLogin(m)).toMatchObject({
      ownership: "managed",
      refreshToken: "machine-refresh",
      expiresAt: machineLogin().expiresAt
    })
    expect((await m.shared.context(accountId))?.env?.CLAUDE_CODE_OAUTH_TOKEN).toBe("machine-access")
    expect(logs).toHaveBeenCalledWith(expect.stringMatching(/adopted and signed Claude Code out$/))
    expect(JSON.stringify(logs.mock.calls)).not.toMatch(/machine-refresh|machine-access/)
  })

  it.each([
    ["darwin", "this Mac"],
    ["linux", "this machine"]
  ])("tells the user once, for a week, on %s", async (platform, machine) => {
    startClock()
    quietLogs()
    const original = Object.getOwnPropertyDescriptor(process, "platform")!
    Object.defineProperty(process, "platform", { value: platform })
    onTestFinished(() => {
      Object.defineProperty(process, "platform", original)
    })
    const m = await fleet().machine("a")
    m.claude.signIn(machineLogin())
    await m.shared.reconcile()

    const notice = await m.shared.notice("claude-code")
    await m.shared.reconcile()

    expect(notice?.message).toBe(
      `Claude is now signed in through Codevisor on all your machines. Claude Code on ${machine} was signed out.`
    )
    expect(await m.shared.notice("claude-code")).toEqual(notice)
    expect(await m.shared.notice("codex")).toBeUndefined()
    vi.setSystemTime(100_000 + weekMs + 1)
    expect(await m.shared.notice("claude-code")).toBeUndefined()
  })

  it("takes over from the access token an earlier build borrowed", async () => {
    startClock()
    quietLogs()
    const f = fleet()
    const m = await f.machine("a")
    const { refreshToken: _refreshToken, ...borrowed } = {
      ...machineLogin(),
      ownership: "external" as const
    }
    const credential = await m.vault.create(borrowed)
    await m.shared.store.save(sharedAccountFor(borrowed, credential, undefined, "a"))
    m.claude.signIn(machineLogin())

    await m.shared.reconcile()

    expect(m.claude.login()).toBeUndefined()
    expect(await vaultLogin(m)).toMatchObject({
      ownership: "managed",
      refreshToken: "machine-refresh"
    })
    expect(f.records.get(credential.id)?.revoked).toBe(true)
  })

  it("announces the notice to subscribers once Claude Code is signed out", async () => {
    startClock()
    quietLogs()
    const m = await fleet().machine("a")
    const announced: unknown[] = []
    const unsubscribe = m.shared.subscribeNotices((harnessId, notice) =>
      announced.push([harnessId, notice, m.claude.login()])
    )
    m.claude.signIn(machineLogin())

    await m.shared.reconcile()
    unsubscribe()

    expect(announced).toEqual([["claude-code", await m.shared.notice("claude-code"), undefined]])
  })

  it("replaces a synced Codevisor credential that can no longer refresh", async () => {
    startClock()
    quietLogs()
    const f = fleet()
    const m = await f.machine("a")
    m.claude.signIn({ ...machineLogin("first-refresh"), expiresAt: 200_000 })
    await m.shared.reconcile()
    const dead = (await m.shared.store.get(accountId))!.credential!
    vi.setSystemTime(300_000)
    f.rotate.mockRejectedValue(new OAuthRefreshRejected(400, "invalid_grant"))
    m.claude.signIn(machineLogin("second-refresh", "second-access"))

    await m.shared.reconcile()

    expect(m.claude.login()).toBeUndefined()
    expect((await m.shared.context(accountId))?.env?.CLAUDE_CODE_OAUTH_TOKEN).toBe("second-access")
    expect(f.records.get(dead.id)?.revoked).toBe(true)
  })

  it.each(["offline", "busy"] as const)(
    "waits when it cannot tell whether Codevisor's credential still works (%s)",
    async (reason) => {
      startClock()
      quietLogs()
      const m = await fleet().machine("a")
      m.claude.signIn(machineLogin("first-refresh"))
      await m.shared.reconcile()
      vi.spyOn(m.vault, "token").mockRejectedValue(new SharedCredentialError(reason))
      m.claude.signIn(machineLogin("signed-in-again"))

      await m.shared.reconcile()

      expect(m.claude.login()?.refreshToken).toBe("signed-in-again")
    }
  )

  it("still finishes when the replaced credential cannot be retired", async () => {
    startClock()
    const logs = quietLogs()
    const f = fleet()
    const m = await f.machine("a")
    m.claude.signIn({ ...machineLogin("first-refresh"), expiresAt: 200_000 })
    await m.shared.reconcile()
    vi.setSystemTime(300_000)
    f.rotate.mockRejectedValue(new OAuthRefreshRejected(400, "invalid_grant"))
    vi.spyOn(m.vault, "revoke").mockRejectedValueOnce(new Error("offline"))
    m.claude.signIn(machineLogin("second-refresh"))

    await m.shared.reconcile()

    expect(m.claude.login()).toBeUndefined()
    expect(await m.shared.notice("claude-code")).toBeDefined()
    expect(logs).toHaveBeenCalledWith(expect.stringMatching(/could not retire the replaced login/))
  })

  it("keeps a separate Claude Code login while Codevisor's credential works, on every machine", async () => {
    startClock()
    quietLogs()
    const f = fleet()
    const a = await f.machine("a")
    const b = await f.machine("b")
    a.claude.signIn(machineLogin("adopted-refresh"))
    await a.shared.reconcile()
    a.claude.signIn(machineLogin("signed-in-again"))
    b.claude.signIn(machineLogin("b-refresh"))

    await a.shared.reconcile()
    await f.sync(a, b)

    expect(a.claude.login()?.refreshToken).toBe("signed-in-again")
    expect(b.claude.login()?.refreshToken).toBe("b-refresh")
    expect(b.claude.signOut).not.toHaveBeenCalled()
    expect((await vaultLogin(b)).refreshToken).toBe("adopted-refresh")
  })

  it("lets only one machine adopt a login under the shared lease", async () => {
    startClock()
    const logs = quietLogs()
    const f = fleet()
    const a = await f.machine("a")
    const b = await f.machine("b")
    a.claude.signIn(machineLogin("a-refresh"))
    b.claude.signIn(machineLogin("b-refresh"))

    await a.shared.reconcile()
    await b.shared.reconcile()

    expect(a.claude.login()).toBeUndefined()
    expect(b.claude.login()?.refreshToken).toBe("b-refresh")
    expect(await b.shared.store.get(accountId)).toBeUndefined()
    expect(logs).toHaveBeenCalledWith(expect.stringMatching(/another machine adopted first$/))
  })

  it("saves the login to the vault before signing Claude Code out", async () => {
    startClock()
    quietLogs()
    const f = fleet()
    const m = await f.machine("a")
    m.claude.signIn(machineLogin())
    const heldAtSignOut: Array<string | undefined> = []
    m.claude.signOut.mockImplementationOnce(async () => {
      heldAtSignOut.push((await vaultLogin(m)).refreshToken)
      m.claude.signIn(undefined)
    })

    await m.shared.reconcile()

    expect(heldAtSignOut).toEqual(["machine-refresh"])
  })

  it("re-reads the login after taking Claude Code's refresh lock", async () => {
    startClock()
    quietLogs()
    const claude = fakeClaudeMachine()
    const m = await fleet().machine("a", undefined, {
      claudeMachine: () => ({
        ...claude.machine,
        whileLocked: (body) => {
          claude.signIn(machineLogin("refreshed-before-lock", "refreshed-access"))
          return claude.machine.whileLocked(body)
        }
      })
    })
    claude.signIn(machineLogin())

    await m.shared.reconcile()

    expect(await vaultLogin(m)).toMatchObject({
      refreshToken: "refreshed-before-lock",
      accessToken: "refreshed-access"
    })
    expect(claude.login()).toBeUndefined()
  })

  it("waits while Claude Code holds its refresh lock", async () => {
    startClock()
    const logs = quietLogs()
    const f = fleet()
    const m = await f.machine("a")
    m.claude.signIn(machineLogin())
    m.claude.refreshing(true)

    await m.shared.reconcile()

    expect(m.claude.login()).toEqual(machineLogin())
    expect(f.records.size).toBe(0)
    expect(logs).toHaveBeenCalledWith(expect.stringContaining("Claude Code is refreshing"))

    m.claude.refreshing(false)
    await m.shared.reconcile()
    expect(m.claude.login()).toBeUndefined()
  })

  it.each<[string, (m: Awaited<ReturnType<ReturnType<typeof fleet>["machine"]>>) => void]>([
    [
      "the vault cannot be reached",
      (m) => vi.spyOn(m.vault, "claim").mockRejectedValueOnce(new Error("offline"))
    ],
    [
      "the account cannot be saved",
      (m) => vi.spyOn(m.shared.store, "save").mockRejectedValueOnce(new Error("disk full"))
    ],
    [
      "the vault does not confirm the write",
      (m) => vi.spyOn(m.vault, "confirm").mockResolvedValueOnce(false)
    ],
    ["Claude Code's refresh lock is lost", (m) => m.claude.loseNextLock()]
  ])("keeps the machine login when %s, then finishes on the next pass", async (_case, fail) => {
    startClock()
    quietLogs()
    const m = await fleet().machine("a")
    m.claude.signIn(machineLogin())
    fail(m)

    await m.shared.reconcile()
    expect(m.claude.login()).toEqual(machineLogin())

    await m.shared.reconcile()
    expect(m.claude.login()).toBeUndefined()
    expect((await vaultLogin(m)).refreshToken).toBe("machine-refresh")
  })

  it("removes the leftover copy on the next pass when signing Claude Code out fails", async () => {
    startClock()
    const logs = quietLogs()
    const m = await fleet().machine("a")
    m.claude.signIn(machineLogin())
    m.claude.signOut.mockRejectedValueOnce(new Error("Keychain locked"))

    await m.shared.reconcile()
    expect(m.claude.login()).toEqual(machineLogin())
    expect((await vaultLogin(m)).refreshToken).toBe("machine-refresh")

    await m.shared.reconcile()
    expect(m.claude.login()).toBeUndefined()
    expect(logs).toHaveBeenCalledWith(expect.stringMatching(/removed a leftover copy/))
  })

  it("leaves a login Claude Code refreshed before the leftover copy could be removed", async () => {
    startClock()
    quietLogs()
    const claude = fakeClaudeMachine()
    let refreshBeforeLock = false
    const m = await fleet().machine("a", undefined, {
      claudeMachine: () => ({
        ...claude.machine,
        whileLocked: (body) => {
          if (refreshBeforeLock) claude.signIn(machineLogin("refreshed-by-claude-code"))
          return claude.machine.whileLocked(body)
        }
      })
    })
    claude.signIn(machineLogin())
    claude.signOut.mockRejectedValueOnce(new Error("Keychain locked"))
    await m.shared.reconcile()
    refreshBeforeLock = true

    await m.shared.reconcile()

    expect(claude.login()?.refreshToken).toBe("refreshed-by-claude-code")
  })

  it("ignores other harnesses and unfinished sign-ins when deciding", async () => {
    startClock()
    quietLogs()
    const m = await fleet().machine("a", native("bob"))
    await m.shared.create("claude-code")
    m.claude.signIn(machineLogin())

    await m.shared.reconcile()

    expect(m.claude.login()).toBeUndefined()
  })

  it("does not bring back an account that was signed out everywhere", async () => {
    startClock()
    quietLogs()
    const m = await fleet().machine("a")
    m.claude.signIn(machineLogin("first-refresh"))
    await m.shared.reconcile()
    await m.shared.logout(accountId, true)
    m.claude.signIn(machineLogin("signed-in-again"))

    await m.shared.reconcile()

    expect(await m.shared.store.get(accountId)).toBeUndefined()
    expect(m.claude.login()?.refreshToken).toBe("signed-in-again")
  })

  it("imports an Anthropic API key from the environment without touching Claude Code", async () => {
    startClock()
    const m = await fleet().machine("a")
    const key = sharedApiKey("claude-code", "sk-ant-fixture")
    m.claude.signIn(key)

    await m.shared.reconcile()

    expect(m.claude.signOut).not.toHaveBeenCalled()
    expect((await m.shared.accounts("claude-code", true))?.[0]?.authMethod).toBe("apiKey")
  })
})
