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
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Codex login methods", () => {
  const methodsFor = async (preferDeviceCode: boolean) => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-codex-auth-methods-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await run(
      db.saveHarnessAccount({
        id: "codex-account",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing Codex account",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      agents: {} as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      preferDeviceCode,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const [decorated] = await manager.decorateHarnesses([
      {
        id: "codex",
        name: "Codex",
        symbolName: "terminal",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: { state: "ready", path: "/usr/local/bin/codex" }
      }
    ])
    return decorated?.auth?.loginMethods.map((method) => method.id)
  }

  it("omits the non-working ChatGPT browser handoff on remote machines", async () => {
    await expect(methodsFor(true)).resolves.toEqual(["chatgptDeviceCode", "apiKey"])
  })

  it("keeps the ChatGPT browser handoff on the local machine", async () => {
    await expect(methodsFor(false)).resolves.toEqual(["chatgpt", "chatgptDeviceCode", "apiKey"])
  })
})

describe("harness authentication decoration", () => {
  it("decorates from stored state without launching a probe", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-stored-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await run(
      db.saveHarnessAccount({
        id: "gemini-account",
        harnessId: "gemini",
        profileKind: "default",
        label: "Existing Gemini CLI account",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const probeHarnessAuth = vi.fn(() =>
      Effect.succeed({ state: "authenticated" as const, methods: [], canLogout: true })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const definition = harnessCatalog.find((candidate) => candidate.id === "gemini")!
    const harness: Harness = {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: "npx",
      enabled: true,
      readiness: { state: "ready", path: "/usr/local/bin/gemini" }
    }

    const [decorated] = await manager.decorateHarnessesFromStoredState([harness])

    expect(decorated).toMatchObject({
      enabled: false,
      desiredEnabled: true,
      auth: { state: "unauthenticated" }
    })
    expect(probeHarnessAuth).not.toHaveBeenCalled()
  })

  it("does not block catalog decoration on a passive account probe", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-passive-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await run(
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

    let finishProbe: (() => void) | undefined
    const probeFinished = new Promise<void>((resolve) => {
      finishProbe = resolve
    })
    const probeHarnessAuth = vi.fn(() =>
      Effect.promise(async () => {
        await probeFinished
        return {
          state: "authenticated" as const,
          methods: [],
          canLogout: true
        }
      })
    )
    const manager = makeHarnessAuthManager({
      agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })
    const definition = harnessCatalog.find((candidate) => candidate.id === "gemini")!
    const harness: Harness = {
      id: definition.id,
      name: definition.name,
      symbolName: definition.symbolName,
      source: "registry",
      launchKind: "npx",
      enabled: true,
      readiness: { state: "ready", path: "/usr/local/bin/gemini" }
    }

    const decorated = await Promise.race([
      manager.decorateHarnesses([harness]),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("catalog decoration waited for auth")), 250)
      )
    ])
    expect(decorated[0]).toMatchObject({
      enabled: false,
      desiredEnabled: true,
      auth: { state: "checking" }
    })
    await vi.waitFor(() => expect(probeHarnessAuth).toHaveBeenCalledOnce())

    finishProbe?.()
    await vi.waitFor(async () => {
      expect(await run(db.getHarnessAccount("gemini-account"))).toMatchObject({
        authState: "authenticated"
      })
    })
  })
})
