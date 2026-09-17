import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
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
})
