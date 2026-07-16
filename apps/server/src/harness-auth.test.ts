import { harnessCatalog, type AgentRuntimeService } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import { makeHarnessAuthManager } from "./harness-auth.js"

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

describe("Pi harness authentication", () => {
  it("routes Pi setup to the native provider manager instead of ACP or a terminal", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-pi-auth-"))
    directories.push(directory)

    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "pi-account",
        harnessId: "pi",
        profileKind: "default",
        label: "Pi configuration",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )

    const authenticateHarness = vi.fn(() => Effect.void)
    const agents = {
      authenticateHarness,
      probeHarnessAuth: vi.fn(() =>
        Effect.succeed({
          state: "unauthenticated" as const,
          methods: [
            {
              id: "pi_terminal_login",
              name: "Launch pi in the terminal",
              description: "Configure Pi providers"
            }
          ],
          canLogout: false
        })
      )
    } as unknown as AgentRuntimeService
    const terminal = {} as TerminalManagerService
    const manager = makeHarnessAuthManager({
      agents,
      dataDir: directory,
      db,
      terminal,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const definition = harnessCatalog.find((candidate) => candidate.id === "pi")!
    const harness: Harness = {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: "npx",
      enabled: true,
      readiness: { state: "ready", path: "/usr/local/bin/pi" }
    }

    const [decorated] = await manager.decorateHarnesses([harness], true)
    expect(decorated?.enabled).toBe(false)
    expect(decorated?.auth?.loginMethods).toEqual([])
    await expect(manager.beginLogin(account.id)).rejects.toThrow(
      "Choose and authenticate a Pi provider in Codevisor settings"
    )
    expect(authenticateHarness).not.toHaveBeenCalled()
  })
})

describe("harness authentication refresh", () => {
  it("refreshes every account when one harness probe fails", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-refresh-"))
    directories.push(directory)

    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await Promise.all([
      run(
        db.saveHarnessAccount({
          id: "pi-account",
          harnessId: "pi",
          profileKind: "default",
          label: "Pi configuration",
          authState: "checking",
          canLogin: true,
          canLogout: false
        })
      ),
      run(
        db.saveHarnessAccount({
          id: "gemini-account",
          harnessId: "gemini",
          profileKind: "default",
          label: "Existing Gemini CLI account",
          authState: "checking",
          canLogin: true,
          canLogout: false
        })
      )
    ])

    const probeHarnessAuth = vi.fn((harnessId: string) =>
      harnessId === "gemini"
        ? Effect.fail(new Error("ACP connection closed"))
        : Effect.succeed({
            state: "notRequired" as const,
            methods: [],
            canLogout: false
          })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })

    await expect(manager.refresh()).resolves.toBeUndefined()

    expect(probeHarnessAuth).toHaveBeenCalledWith("pi", expect.any(Object))
    expect(probeHarnessAuth).toHaveBeenCalledWith("gemini", expect.any(Object))
    await expect(run(db.getHarnessAccount("pi-account"))).resolves.toMatchObject({
      authState: "notRequired"
    })
    await expect(run(db.getHarnessAccount("gemini-account"))).resolves.toMatchObject({
      authState: "error",
      canLogout: false
    })
  })
})
