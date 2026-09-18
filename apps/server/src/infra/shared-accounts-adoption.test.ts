import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeHarnessAuthManager, sharedOAuthIdentity } from "@codevisor/harness-manager"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { fleet, native } from "./shared-accounts-test-support.js"

afterEach(() => vi.useRealTimers())

describe("adopting an existing terminal login", () => {
  it("offers a freshly adopted native login as signed in on the first catalog read", async () => {
    // Onboarding's first `GET /v1/harnesses` runs discovery and then reads the
    // stored snapshot without waiting for a probe. A grant adopted from a live
    // token must already read as authenticated, or the row sits on
    // "Checking sign-in…" and the harness stays disabled.
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
      agents: {} as AgentRuntimeService,
      terminal: {} as TerminalManagerService,
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

describe("signing out on one machine", () => {
  it("keeps the catalog quiet: reconcile must not flip sign-out availability back", async () => {
    // A machine sign-out keeps the shared grant. `reconcile()` re-saves every
    // shared row on each catalog read; if it recomputed `canLogout` from the
    // grant, the following probe would flip it back and announce a change
    // every time — and listening clients would refetch forever.
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const a = await fleet().machine("a", native("alice"))
    await a.shared.reconcile()
    const id = sharedOAuthIdentity(native("alice"))
    const manager = makeHarnessAuthManager({
      db: a.db,
      dataDir: a.dataDir,
      agents: {} as AgentRuntimeService,
      terminal: {} as TerminalManagerService,
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
