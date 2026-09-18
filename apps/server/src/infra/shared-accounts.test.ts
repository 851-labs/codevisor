import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import {
  makeHarnessAuthManager,
  sharedOAuthIdentity,
  sharedApiKey
} from "@codevisor/harness-manager"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { fleet, native } from "./shared-accounts-test-support.js"
import { makeSharedAccounts } from "./shared-accounts.js"
afterEach(() => vi.useRealTimers())
describe("automatic shared accounts", () => {
  it("hides pending sign-in profiles and imported aliases from cached catalog accounts", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const a = await fleet().machine("a", native("alice"))
    await Effect.runPromise(
      a.db.saveHarnessAccount({
        id: "native-default",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing Codex account",
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
    await a.shared.reconcile()
    const id = sharedOAuthIdentity(native("alice"))
    const pending = await a.shared.prepareLogin(id)
    expect(await Effect.runPromise(a.db.getHarnessAccount(pending))).toBeDefined()
    expect(await Effect.runPromise(a.db.getHarnessAccount("native-default"))).toBeDefined()
    const token = vi.spyOn(a.vault, "token")
    expect((await a.shared.storedAccounts("codex"))?.map((account) => account.id)).toEqual([id])
    expect(await a.shared.storedAccounts("cursor")).toBeUndefined()
    expect(token).not.toHaveBeenCalled()
  })

  it("keeps catalog accounts aligned with the account sheet without credential probes", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a", native("alice"))
    await a.shared.reconcile()
    const id = sharedOAuthIdentity(native("alice"))
    await a.shared.logout(id, true)
    expect(await Effect.runPromise(a.db.getHarnessAccount(id))).toBeDefined()
    await Effect.runPromise(
      a.db.saveHarnessAccount({
        id: "native-default",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing Codex account",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      db: a.db,
      dataDir: a.dataDir,
      agents: {} as AgentRuntimeService,
      terminal: {} as TerminalManagerService,
      sharedAccounts: () => a.shared,
      resolveEnv: async () => ({ HOME: a.dataDir })
    })
    const token = vi.spyOn(a.vault, "token")
    const decorate = () =>
      manager.decorateHarnessesFromStoredState([
        {
          id: "codex",
          name: "Codex",
          symbolName: "terminal",
          source: "registry",
          launchKind: "executable",
          enabled: true,
          readiness: { state: "ready" }
        }
      ])
    const [empty] = await decorate()
    expect(empty?.auth?.accounts.some((account) => account.id === id)).toBe(false)
    expect(empty?.auth?.state).toBe("unauthenticated")
    const saved = await a.shared.create("codex", "Work")
    const [configured] = await decorate()
    expect(configured?.auth?.accounts.map((account) => account.id)).toContain(saved.id)
    expect(token).not.toHaveBeenCalled()
    token.mockRestore()
    expect(new Set((await a.shared.accounts("codex"))?.map((account) => account.id))).toEqual(
      new Set(configured?.auth?.accounts.map((account) => account.id))
    )
  })

  it("imports the first login and adds a different joining login without changing the shared default", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a", native("alice"))
    await a.shared.reconcile()
    const alice = sharedOAuthIdentity(native("alice"))
    expect((await a.shared.accounts("codex", true))?.map((row) => [row.id, row.isActive])).toEqual([
      [alice, true]
    ])
    vi.setSystemTime(101_000)
    const b = await f.machine("b", native("bob"))
    await f.sync(a, b)
    await f.sync(b, a)
    const accounts = await b.shared.accounts("codex", true)
    expect(accounts).toHaveLength(2)
    expect(accounts?.find((row) => row.isActive)?.id).toBe(alice)
    expect((await b.shared.context(alice))?.oauth).toBeDefined()
    expect(f.rotate).not.toHaveBeenCalled()
    expect(JSON.stringify([...f.records.values()])).not.toContain("access-alice")
  })

  it("deduplicates the same provider identity and keeps separate workspaces", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a", native("alice")),
      b = await f.machine("b", native("alice"))
    await a.shared.reconcile()
    await f.sync(a, b)
    expect(await b.shared.accounts("codex", true)).toHaveLength(1)
    b.setBundle({ ...native("alice"), organizationId: "personal" })
    await b.shared.reconcile()
    await f.sync(b, a)
    expect(await a.shared.accounts("codex", true)).toHaveLength(2)
  })

  it.each([false, true])(
    "resumes following shared changes after selecting the shared account (explicit default: %s)",
    async (explicit) => {
      vi.useFakeTimers({ toFake: ["Date"] })
      vi.setSystemTime(100_000)
      const f = fleet(),
        a = await f.machine("a", native("alice"))
      await a.shared.reconcile()
      vi.setSystemTime(101_000)
      const b = await f.machine("b", native("bob"))
      await f.sync(a, b)
      await f.sync(b, a)
      const alice = sharedOAuthIdentity(native("alice")),
        bob = sharedOAuthIdentity(native("bob"))
      if (explicit) {
        await a.shared.activate("codex", alice, true)
        await f.sync(a, b)
      }
      await b.shared.activate("codex", bob)
      await f.sync(b, a)
      expect((await b.shared.accounts("codex"))?.find((row) => row.isActive)?.id).toBe(bob)
      expect((await b.shared.accounts("codex", true))?.find((row) => row.isActive)?.id).toBe(alice)
      expect((await a.shared.accounts("codex"))?.find((row) => row.isActive)?.id).toBe(alice)
      expect(await b.shared.store.overridden("codex")).toBe(true)
      await b.shared.activate("codex", alice)
      expect((await b.shared.accounts("codex"))?.find((row) => row.isActive)).toMatchObject({
        id: alice,
        selectionScope: "shared"
      })
      expect(await b.shared.store.overridden("codex")).toBe(false)
      await a.shared.activate("codex", bob, true)
      await f.sync(a, b)
      expect((await b.shared.accounts("codex"))?.find((row) => row.isActive)).toMatchObject({
        id: bob,
        selectionScope: "shared"
      })
    }
  )

  it("signs out one machine without revoking the grant and prevents resurrection after global sign-out", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a", native("alice")),
      b = await f.machine("b", native("alice"))
    await a.shared.reconcile()
    await f.sync(a, b)
    const id = sharedOAuthIdentity(native("alice"))
    await b.shared.logout(id)
    await expect(b.shared.context(id)).rejects.toThrow("signed out")
    expect((await a.shared.probe(id))?.authState).toBe("authenticated")
    expect((await b.shared.accounts("codex", true))?.[0]?.authState).toBe("authenticated")
    await b.shared.inherit("codex")
    expect((await b.shared.probe(id))?.authState).toBe("authenticated")
    await a.shared.logout(id, true)
    await f.sync(a, b)
    await expect(b.shared.context(id)).rejects.toThrow("signed out")
    expect(await b.shared.accounts("codex", true)).toEqual([])
  })

  it("drops locally held credentials when a change arrives from another machine", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a", native("alice")),
      b = await f.machine("b", native("alice"))
    await a.shared.reconcile()
    await f.sync(a, b)
    const id = sharedOAuthIdentity(native("alice"))
    const credential = (await b.shared.store.get(id))!.credential!
    expect((await b.vault.token(credential)).subject).toBe("alice")
    // Revoked at the coordinator, but B still holds a confirmed credential
    // inside its revalidation window and keeps serving it.
    await a.vault.revoke(credential)
    expect((await b.vault.token(credential)).subject).toBe("alice")
    // The periodic sweep leaves held credentials alone…
    await b.shared.reconcile()
    expect((await b.vault.token(credential)).subject).toBe("alice")
    // …while a sync-driven reconcile re-reads them.
    await b.shared.reconcileRemote()
    await expect(b.vault.token(credential)).rejects.toThrow("signed out")
  })

  it("captures an isolated managed login and refreshes it from a second machine", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const placeholder = await a.shared.create("codex")
    const fresh = await a.shared.prepareLogin(placeholder.id)
    expect(fresh).not.toBe(placeholder.id)
    expect((await a.shared.probe(placeholder.id))?.authState).toBe("checking")
    a.setBundle({ ...native("alice"), ownership: "managed", refreshToken: "grant", expiresAt: 1 })
    await a.shared.captureLogin(fresh)
    a.setBundle(undefined)
    await f.sync(a, b)
    const id = sharedOAuthIdentity(native("alice"))
    expect((await b.shared.context(id))?.oauth).toBeDefined()
    expect(f.rotate).toHaveBeenCalledOnce()
    expect(await a.shared.store.get(placeholder.id)).toBeUndefined()
  })

  it("shares API keys through the same account editor without exposing them in account responses", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const placeholder = await a.shared.create("claude-code")
    await a.shared.saveApiKey(placeholder.id, "test-api-secret")
    await f.sync(a, b)
    const accounts = (await b.shared.accounts("claude-code", true))!
    expect(accounts).toHaveLength(1)
    expect(accounts[0]?.authMethod).toBe("apiKey")
    expect(JSON.stringify(accounts)).not.toContain("test-api-secret")
    expect((await b.shared.context(accounts[0]!.id))?.env?.ANTHROPIC_API_KEY).toBe(
      "test-api-secret"
    )
  })
})

it("keeps legacy accounts usable, recovers an interrupted managed login, and preserves its label", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet(),
    m = await f.machine("a")
  const legacy = await m.auth.createAccount("codex", "Work")
  expect((await m.shared.accounts("codex"))?.map((row) => row.id)).toContain(legacy.id)
  const fresh = await m.shared.prepareLogin(legacy.id)
  expect(await m.shared.probe(fresh)).toBeUndefined()
  expect(await m.shared.probe("legacy-missing")).toBeUndefined()
  await expect(m.shared.captureLogin(fresh)).rejects.toThrow("Sign-in could not be saved")
  await m.shared.captureLogin("missing")
  await m.shared.captureLogin(legacy.id)
  m.setBundle({ ...native("alice"), ownership: "managed", refreshToken: "grant" })
  const restarted = m.restart()
  await restarted.reconcile()
  const id = sharedOAuthIdentity(native("alice"))
  expect((await restarted.accounts("codex", true))?.find((row) => row.id === id)?.label).toBe(
    "Work"
  )
  expect((await restarted.context(legacy.id))?.id).toBe(id)
  expect((await restarted.context(fresh))?.id).toBe(id)
  await expect((await restarted.context(id))?.oauth?.token()).resolves.toMatchObject({
    accessToken: "access-alice",
    accountId: "work"
  })
  const next = await restarted.prepareLogin(id)
  await restarted.loginFailed(next)
  await restarted.loginFailed("missing")
  expect((await restarted.probe(id))?.authState).toBe("authenticated")
  expect(await restarted.prepareLogin("missing")).toBe("missing")
  expect(await restarted.prepareLogin(id, "apiKey")).toBe(id)
  expect(await restarted.accounts("pi")).toBeUndefined()
  expect(await restarted.context("legacy-missing")).toBeUndefined()
  await expect(restarted.context("shared-missing")).rejects.toThrow("signed out")
})
it("replaces an existing managed login without leaving its previous grant active", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet(),
    m = await f.machine("a", native("alice"))
  await m.shared.reconcile()
  const id = sharedOAuthIdentity(native("alice")),
    first = (await m.shared.store.get(id))!.credential!
  const fresh = await m.shared.prepareLogin(id)
  m.setBundle({ ...native("alice"), ownership: "managed", refreshToken: "new-grant" })
  await m.shared.captureLogin(fresh)
  expect(f.records.get(first.id)?.revoked).toBe(true)
  expect((await m.shared.store.get(id))?.credential?.id).not.toBe(first.id)
  await expect(m.shared.activate("claude-code", id)).rejects.toThrow("another harness")
  expect(await m.shared.activate("codex", "missing")).toBe(false)
  const placeholder = await m.shared.create("codex", "   ")
  await expect(m.shared.activate("codex", placeholder.id)).rejects.toThrow("Sign in")
  expect(await m.shared.logout("missing")).toBeUndefined()
  await expect(m.shared.rename("missing", "x")).rejects.toThrow("not found")
  const label = (await m.shared.rename(id, " "))?.label
  expect(label).toBe("alice@example.test")
  await expect(m.shared.saveApiKey("missing", "key")).rejects.toThrow("Enter an API key")
  await expect(m.shared.saveApiKey(id, " ")).rejects.toThrow("Enter an API key")
})
it("builds isolated Claude contexts and keeps machine sign-out separate from the shared editor", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet(),
    m = await f.machine("a", { ...native("alice"), harnessId: "claude-code" })
  await m.shared.reconcile()
  const id = sharedOAuthIdentity({ ...native("alice"), harnessId: "claude-code" })
  const context = await m.shared.context(id)
  expect(context?.env).toMatchObject({
    CLAUDE_CODE_OAUTH_TOKEN: "access-alice",
    ANTHROPIC_BASE_URL: "http://127.0.0.1:1/harness/claude"
  })
  expect(JSON.stringify(context)).not.toContain("refreshToken")
  await m.shared.logout(id)
  expect((await m.shared.accounts("claude-code"))?.[0]).toMatchObject({
    authState: "expired",
    selectionScope: "machine"
  })
  expect((await m.shared.accounts("claude-code", true))?.[0]?.authState).toBe("authenticated")
  expect((await m.shared.probe(id))?.authState).toBe("expired")
  await m.shared.inherit("claude-code")
  expect((await m.shared.probe(id))?.authState).toBe("authenticated")
})

it("adopts legacy isolated profiles independently of default credentials and recovers a cancelled login", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet()
  const m = await f.machine("a", undefined, {
    discover: async (harness, _path, isDefault) =>
      harness === "codex" && !isDefault ? native("legacy") : undefined
  })
  const legacy = await m.auth.createAccount("codex", "Old Profile")
  await m.shared.reconcile()
  expect((await m.shared.context(legacy.id))?.id).toBe(sharedOAuthIdentity(native("legacy")))
  const next = await m.shared.prepareLogin(legacy.id)
  await m.shared.loginFailed(next)
  await m.shared.reconcile()
  expect((await m.shared.accounts("codex", true))?.[0]?.authState).toBe("authenticated")
  expect(await m.shared.accounts("claude-code")).toEqual([])
})
it("keeps errors private, handles incomplete synced records, and supports both API-key providers", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet(),
    m = await f.machine("a")
  const claude = await m.shared.create("claude-code"),
    codex = await m.shared.create("codex")
  expect((await m.shared.accounts("claude-code", true))?.[0]?.detail).toContain("signed out")
  await m.shared.saveApiKey(codex.id, "codex-key")
  await m.shared.saveApiKey(claude.id, "claude-key")
  const id = (await m.shared.accounts("codex", true))![0]!.id
  expect((await m.shared.context(id))?.env?.OPENAI_API_KEY).toBe("codex-key")
  await m.shared.saveApiKey(id, "codex-key")
  await m.shared.inherit("codex")
  const key = (await m.shared.store.get(id))!.credential!
  const original = m.vault.token
  m.vault.token = async () => {
    throw new Error("SECRET")
  }
  expect((await m.shared.probe(id, true))?.detail).toBe("Account sync is unavailable. Try again.")
  expect((await m.shared.probe(id))?.detail).not.toContain("SECRET")
  await m.shared.reconcile()
  m.vault.token = original
  await m.shared.store.save({
    id: "shared-undiscovered",
    harnessId: "codex",
    label: "Later",
    createdAt: 1,
    credential: key
  })
  expect(await m.shared.probe("shared-undiscovered")).toBeUndefined()
  expect(await m.shared.probe("shared-missing")).toBeUndefined()
  const other = await m.auth.createAccount("pi", "Pi")
  expect(await m.shared.prepareLogin(other.id)).toBe(other.id)
  await expect(m.shared.saveApiKey(other.id, "key")).rejects.toThrow("Enter an API key")
})
it("handles anonymous account labels, explicit native directories, and missing workspace metadata", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet()
  const bundle = {
    harnessId: "codex" as const,
    subject: "subject",
    accessToken: "access",
    ownership: "external" as const,
    expiresAt: 10_000_000,
    planType: "plus"
  }
  const m = await f.machine("a", bundle, {
    environment: async () => ({
      CODEX_HOME: "/fixture/codex",
      CLAUDE_CONFIG_DIR: "/fixture/claude"
    })
  })
  await m.shared.reconcile()
  const id = sharedOAuthIdentity(bundle)
  expect((await m.shared.accounts("codex", true))?.[0]?.label).toBe("ChatGPT")
  expect(await (await m.shared.context(id))?.oauth?.token()).toEqual({
    accessToken: "access",
    planType: "plus"
  })
  m.setBundle({ ...bundle, harnessId: "claude-code" })
  expect((await m.shared.accounts("claude-code", true))?.[0]?.label).toBe("Claude")
  const blank = await f.machine("empty", undefined, { environment: async () => ({}) })
  await blank.shared.reconcile()
})

it("handles a removed row during probing and ignores invalid persisted login intents", async () => {
  const f = fleet(),
    m = await f.machine("a", undefined, {
      discover: async (harness) =>
        harness === "codex" ? sharedApiKey("codex", "native-key") : undefined
    })
  await m.shared.reconcile()
  await m.shared.reconcile()
  const other = await m.auth.createAccount("pi", "Pi")
  await Effect.runPromise(
    m.db.mergeSyncEntries("local.shared-accounts", [
      {
        key: `login:${other.id}`,
        value: "target",
        timestamp: { wallMs: 1, counter: 0, deviceId: "a" }
      }
    ])
  )
  await expect(m.shared.captureLogin(other.id)).rejects.toThrow("Sign-in could not be saved")
  const defaults = makeSharedAccounts({
    db: m.db,
    auth: m.auth,
    dataDir: m.dataDir,
    serverId: "b",
    baseUrl: "http://127.0.0.1:1"
  })
  expect(await defaults.accounts("pi")).toBeUndefined()
  defaults.gateway.close()
  const get = m.db.getHarnessAccount
  const lookup = vi
    .spyOn(m.db, "getHarnessAccount")
    .mockImplementation((id) => Effect.map(get(id), () => undefined))
  try {
    expect(await m.shared.accounts("codex", true)).toEqual([])
  } finally {
    lookup.mockRestore()
  }
})

it("upgrades an existing Codevisor profile into managed refresh ownership without another sign-in", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet(),
    bundle = native("alice")
  const m = await f.machine("a", undefined, {
    discover: async (harness, _path, isDefault, managed) =>
      harness !== "codex"
        ? undefined
        : isDefault
          ? bundle
          : {
              ...bundle,
              ownership: managed ? "managed" : "external",
              refreshToken: "owned-grant",
              expiresAt: 1
            }
  })
  await m.shared.reconcile()
  const id = sharedOAuthIdentity(bundle),
    old = (await m.shared.store.get(id))!.credential!
  await m.auth.createAccount("codex", "Existing Codevisor Profile")
  await m.shared.reconcile()
  expect(f.records.get(old.id)?.revoked).toBe(true)
  expect((await m.shared.store.get(id))?.sourceMachineId).toBeUndefined()
  expect((await m.shared.probe(id))?.authState).toBe("authenticated")
  expect(f.rotate).toHaveBeenCalledOnce()
})
