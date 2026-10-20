import {
  makeHarnessAuthManager,
  OAuthRefreshRejected,
  sharedOAuthIdentity
} from "@codevisor/harness-manager"
import { Effect } from "effect"
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { fleet, native } from "./shared-accounts-test-support.js"

afterEach(() => vi.useRealTimers())

describe("adopting an existing terminal login", () => {
  it("offers a freshly adopted native login as signed in on the first catalog read", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const a = await fleet().machine("a", native("alice"))
    await Effect.runPromise(
      a.db.saveHarnessAccount({
        id: "native-default",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing Codex account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    const token = vi.spyOn(a.vault, "token")
    await a.shared.reconcile()
    const id = sharedOAuthIdentity(native("alice"))
    await expect(Effect.runPromise(a.db.getHarnessAccount(id))).resolves.toMatchObject({
      authState: "authenticated",
      authMethod: "oauth",
      email: "alice@example.test",
      isActive: true
    })
    const manager = makeHarnessAuthManager({
      db: a.db,
      dataDir: a.dataDir,
      agents: a.services.agents,
      terminal: a.services.terminal,
      sharedAccounts: () => a.shared,
      resolveEnv: async () => ({ HOME: a.dataDir })
    })
    const [codex] = await manager.decorateHarnessesFromStoredState([
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
    expect(codex?.enabled).toBe(true)
    expect(codex?.auth?.state).toBe("authenticated")
    expect(codex?.auth?.accounts.map((account) => account.id)).toEqual([id])
    expect(token).not.toHaveBeenCalled()
  })

  it("leaves an adopted login on checking when its mirrored token is already stale", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(native("alice").expiresAt - 10_000)
    const a = await fleet().machine("a", native("alice"))
    await a.shared.reconcile()
    await expect(
      Effect.runPromise(a.db.getHarnessAccount(sharedOAuthIdentity(native("alice"))))
    ).resolves.toMatchObject({ authState: "checking" })
  })
})

const signedInToCodex = async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const f = fleet()
  const m = await f.machine("a")
  const placeholder = await m.shared.create("codex")
  const loginProfile = await m.shared.prepareLogin(placeholder.id)
  m.setBundle({
    ...native("alice"),
    ownership: "managed",
    refreshToken: "codevisor-refresh",
    expiresAt: 1
  })
  await m.shared.captureLogin(loginProfile)
  m.setBundle(native("alice"))
  return { f, m, id: sharedOAuthIdentity(native("alice")) }
}

describe("preferring this machine's Codex login over a dead Codevisor credential", () => {
  it("keeps the synced sign-in while it still refreshes", async () => {
    const { m, id } = await signedInToCodex()

    await m.shared.reconcile()

    expect((await (await m.shared.context(id))?.oauth?.token())?.accessToken).toBe("rotated")
  })

  it("borrows the machine login when the synced sign-in can no longer refresh", async () => {
    const { f, m, id } = await signedInToCodex()
    const dead = (await m.shared.store.get(id))!.credential!
    f.rotate.mockRejectedValue(new OAuthRefreshRejected(400, "invalid_grant"))
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    onTestFinished(() => errors.mockRestore())

    await m.shared.reconcile()

    expect((await (await m.shared.context(id))?.oauth?.token())?.accessToken).toBe("access-alice")
    expect(f.records.get(dead.id)?.revoked).toBe(true)
  })
})

describe("signing out on one machine", () => {
  it("keeps the catalog quiet: reconcile must not flip sign-out availability back", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const a = await fleet().machine("a", native("alice"))
    await a.shared.reconcile()
    const id = sharedOAuthIdentity(native("alice"))
    const manager = makeHarnessAuthManager({
      db: a.db,
      dataDir: a.dataDir,
      agents: a.services.agents,
      terminal: a.services.terminal,
      sharedAccounts: () => a.shared,
      resolveEnv: async () => ({ HOME: a.dataDir })
    })
    const harness = {
      id: "codex" as const,
      name: "Codex",
      symbolName: "terminal",
      source: "registry" as const,
      launchKind: "executable" as const,
      enabled: true,
      readiness: { state: "ready" as const }
    }
    await manager.decorateHarnesses([harness], true)
    const events: string[] = []
    manager.subscribe((event) => events.push(event.kind))
    expect(await manager.logout(id)).toMatchObject({ authState: "expired", canLogout: false })
    expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])

    for (let i = 0; i < 3; i += 1) {
      const [codex] = await manager.decorateHarnesses([harness], true)
      expect(codex?.auth?.accounts).toEqual([
        expect.objectContaining({ id, authState: "expired", canLogout: false })
      ])
    }
    expect(events).toHaveLength(2)
  })
})
