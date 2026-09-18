import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { harnessCatalog, type AgentRuntimeService } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
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

    const probeStarted = Promise.withResolvers<void>()
    const accountUpdated = Promise.withResolvers<void>()
    let finishProbe: (() => void) | undefined
    const probeFinished = new Promise<void>((resolve) => {
      finishProbe = resolve
    })
    const probeHarnessAuth = vi.fn(() =>
      Effect.promise(async () => {
        probeStarted.resolve()
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

    const unsubscribe = manager.subscribe((event) => {
      if (event.kind === "harness.account.updated") accountUpdated.resolve()
    })
    const decorated = await manager.decorateHarnesses([harness])
    expect(decorated[0]).toMatchObject({
      enabled: false,
      desiredEnabled: true,
      auth: { state: "checking" }
    })
    await probeStarted.promise
    expect(probeHarnessAuth).toHaveBeenCalledOnce()

    finishProbe?.()
    await accountUpdated.promise
    unsubscribe()
    expect(await run(db.getHarnessAccount("gemini-account"))).toMatchObject({
      authState: "authenticated"
    })
  })
})

it("probes the selected shared account and publishes readiness when its credentials arrive", async () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-shared-readiness-"))
  directories.push(directory)
  const db = await run(makeDatabase({ filename: join(directory, "db.sqlite"), serverId: "test" }))
  databases.push(db)
  for (const [id, profileKind] of [
    ["default", "default"],
    ["shared-selected", "managed"]
  ] as const)
    await run(
      db.saveHarnessAccount({
        id,
        harnessId: "codex",
        label: id,
        profileKind,
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
  await run(db.setActiveHarnessAccount("codex", "shared-selected"))
  const probe = vi.fn(async (id: string) => {
    expect(id).toBe("shared-selected")
    return run(
      db.updateHarnessAccountAuth(id, { authState: "authenticated", canLogout: true, detail: null })
    )
  })
  const manager = makeHarnessAuthManager({
    db,
    dataDir: directory,
    agents: {} as AgentRuntimeService,
    terminal: {} as TerminalManagerService,
    resolveEnv: async () => ({ HOME: directory }),
    sharedAccounts: () =>
      ({
        reconcile: async () => {},
        probe
      }) as unknown as import("./shared-account-integration.js").SharedAccountIntegration
  })
  const events: string[] = [],
    stop = manager.subscribe((event) => {
      events.push(event.kind)
    })
  const harness: Harness = {
    id: "codex",
    name: "Codex",
    symbolName: "terminal",
    source: "registry",
    launchKind: "executable",
    enabled: true,
    readiness: { state: "ready", path: "/fixture/codex" }
  }
  expect((await manager.decorateHarnesses([harness], true))[0]).toMatchObject({
    enabled: true,
    auth: { activeAccountId: "shared-selected", state: "authenticated" }
  })
  expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])
  await manager.decorateHarnesses([harness], true)
  expect(events).toHaveLength(2)
  stop()
})

it("announces a shared sign-out so catalogs on other clients follow", async () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-shared-logout-"))
  directories.push(directory)
  const db = await run(makeDatabase({ filename: join(directory, "db.sqlite"), serverId: "test" }))
  databases.push(db)
  await run(
    db.saveHarnessAccount({
      id: "shared-selected",
      harnessId: "claude-code",
      label: "alice@example.test",
      profileKind: "managed",
      authState: "authenticated",
      canLogin: true,
      canLogout: true
    })
  )
  // The shared store settles sign-out state itself, without a probe.
  const logout = vi.fn(async (id: string) =>
    run(
      db.updateHarnessAccountAuth(id, {
        authState: "expired",
        canLogout: false,
        detail: "This account has been signed out."
      })
    )
  )
  const manager = makeHarnessAuthManager({
    db,
    dataDir: directory,
    agents: {} as AgentRuntimeService,
    terminal: {} as TerminalManagerService,
    resolveEnv: async () => ({ HOME: directory }),
    sharedAccounts: () =>
      ({
        reconcile: async () => {},
        logout
      }) as unknown as import("./shared-account-integration.js").SharedAccountIntegration
  })
  const events: string[] = [],
    stop = manager.subscribe((event) => events.push(event.kind))
  expect(await manager.logout("shared-selected")).toMatchObject({ authState: "expired" })
  expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])
  // Signing out an already signed-out account changes nothing clients render.
  await manager.logout("shared-selected")
  expect(events).toHaveLength(2)
  stop()
})

it("emits auth events only when a probe changes what clients render", async () => {
  // Clients refetch the catalog on `harness.auth.updated`, and that refetch
  // re-probes. A probe that only stamps `lastCheckedAt` must stay silent or
  // the two would chase each other forever.
  const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-quiet-probe-"))
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
  let state: "authenticated" | "unauthenticated" = "authenticated"
  const probeHarnessAuth = vi.fn(() =>
    Effect.succeed({ state, methods: [], canLogout: state === "authenticated" })
  )
  const manager = makeHarnessAuthManager({
    agents: { probeHarnessAuth } as unknown as AgentRuntimeService,
    dataDir: directory,
    db,
    terminal: {} as TerminalManagerService,
    resolveEnv: () => Promise.resolve({ HOME: directory })
  })
  const events: string[] = []
  manager.subscribe((event) => events.push(event.kind))

  await manager.refresh("gemini")
  expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])

  await manager.refresh("gemini")
  expect(probeHarnessAuth).toHaveBeenCalledTimes(2)
  expect(events).toHaveLength(2)
  await expect(run(db.getHarnessAccount("gemini-account"))).resolves.toMatchObject({
    authState: "authenticated",
    lastCheckedAt: expect.any(String)
  })

  state = "unauthenticated"
  await manager.refresh("gemini")
  expect(events).toHaveLength(4)
  await expect(run(db.getHarnessAccount("gemini-account"))).resolves.toMatchObject({
    authState: "unauthenticated"
  })
})
