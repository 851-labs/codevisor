import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import { makeHarnessAuthManager } from "./harness-auth.js"
import type { SharedProviderIntegration } from "./shared-provider-integration.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  vi.useRealTimers()
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("shared provider authentication", () => {
  it("shows a disabled shared provider as signed out while preserving the terminal's credential", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-pi-disabled-"))
    directories.push(directory)
    const path = join(directory, ".pi", "agent", "auth.json")
    mkdirSync(join(path, ".."), { recursive: true })
    writeFileSync(
      path,
      JSON.stringify({
        anthropic: {
          type: "oauth",
          access: "terminal",
          refresh: "terminal-refresh",
          expires: 3_600_000
        }
      })
    )
    const db = await run(
      makeDatabase({ filename: join(directory, "test.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const shared: SharedProviderIntegration = {
      capture: async () => false,
      configured: vi.fn(async () => [] as string[]),
      remove: async () => true,
      disabled: async () => ["anthropic"],
      context: async (_account, base) => base
    }
    const manager = makeHarnessAuthManager({
      db,
      dataDir: directory,
      terminal: {} as TerminalManagerService,
      agents: {} as AgentRuntimeService,
      resolveEnv: async () => ({ HOME: directory }),
      sharedProviders: () => shared
    })
    expect(
      (await manager.piProviders!()).find((provider) => provider.id === "anthropic")?.credentialType
    ).toBeUndefined()
    expect(existsSync(path)).toBe(true)
    vi.mocked(shared.configured).mockResolvedValueOnce(["anthropic"])
    expect(
      (await manager.piProviders!()).find((provider) => provider.id === "anthropic")?.credentialType
    ).toBe("oauth")
  })
  it("captures Grok's isolated first-party login and signs out without touching terminal-owned credentials", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-grok-auth-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "test.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "grok-default",
        harnessId: "grok-build",
        profileKind: "default",
        label: "Grok",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const credential = {
      auth_mode: "oidc",
      key: "fixture-access",
      refresh_token: "fixture-refresh"
    }
    let isolated = ""
    const authenticateHarness = vi.fn((_harness, _method, context) =>
      Effect.sync(() => {
        isolated = context.env.GROK_HOME
        writeFileSync(join(isolated, "auth.json"), JSON.stringify({ default: credential }))
      })
    )
    const logoutHarness = vi.fn(() => Effect.void)
    const shared: SharedProviderIntegration = {
      capture: vi.fn(async () => true),
      configured: async () => ["xai"],
      remove: vi.fn(async () => true),
      context: async (_account, base) => base
    }
    const manager = makeHarnessAuthManager({
      db,
      dataDir: directory,
      terminal: {} as TerminalManagerService,
      resolveEnv: async () => ({ HOME: directory }),
      sharedProviders: () => shared,
      agents: {
        authenticateHarness,
        logoutHarness,
        probeHarnessAuth: () =>
          Effect.succeed({ state: "authenticated", methods: [], canLogout: true })
      } as unknown as AgentRuntimeService
    })
    expect((await manager.beginLogin(account.id, "grok.com")).kind).toBe("complete")
    expect(shared.capture).toHaveBeenCalledWith("grok-build", "default", "xai", credential)
    expect(isolated).toContain(join(directory, "harness-logins", "grok-build"))
    expect(existsSync(isolated)).toBe(false)
    await manager.logout(account.id)
    expect(shared.remove).toHaveBeenCalledWith("grok-build", "default", "xai")
    expect(logoutHarness).not.toHaveBeenCalled()
    vi.mocked(shared.capture).mockResolvedValueOnce(false)
    await expect(manager.beginLogin(account.id, "grok.com")).rejects.toThrow("first-party")
    expect(existsSync(isolated)).toBe(false)
  })
})
