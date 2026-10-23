import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { harnessCatalog } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeHarnessAuthManager } from "./harness-auth.js"
import {
  fakeAgentRuntime,
  fakeSharedAccounts,
  fakeTerminalManager
} from "./harness-lifecycle-test-support.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const codexMethodsFor = async (preferDeviceCode: boolean) => {
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
    agents: fakeAgentRuntime(),
    dataDir: directory,
    db,
    terminal: fakeTerminalManager(),
    preferDeviceCode,
    resolveEnv: () => Promise.resolve({ HOME: directory })
  })
  const [decorated] = await manager.decorateHarnessesFromStoredState([
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

describe("Codex login methods", () => {
  it("omits the non-working ChatGPT browser handoff on remote machines", async () => {
    await expect(codexMethodsFor(true)).resolves.toEqual(["chatgptDeviceCode", "apiKey"])
  })

  it("keeps the ChatGPT browser handoff on the local machine", async () => {
    await expect(codexMethodsFor(false)).resolves.toEqual([
      "chatgpt",
      "chatgptDeviceCode",
      "apiKey"
    ])
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
      agents: fakeAgentRuntime({ probeHarnessAuth }),
      dataDir: directory,
      db,
      terminal: fakeTerminalManager(),
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

  it("carries the active account's failure onto the harness auth", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-detail-"))
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
        authState: "error",
        detail: "Internal error: service failure",
        canLogin: true,
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      agents: fakeAgentRuntime(),
      dataDir: directory,
      db,
      terminal: fakeTerminalManager(),
      resolveEnv: () => Promise.resolve({ HOME: directory })
    })

    const [decorated] = await manager.decorateHarnessesFromStoredState([
      {
        id: "gemini",
        name: "Gemini CLI",
        symbolName: "diamond",
        source: "registry",
        launchKind: "npx",
        enabled: true,
        readiness: { state: "ready", path: "/usr/local/bin/gemini" }
      }
    ])

    expect(decorated?.auth).toMatchObject({
      state: "error",
      detail: "Internal error: service failure"
    })
  })

  it("settles on the account check already running without repeating finished checks", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-auth-settle-"))
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
    const probe = Promise.withResolvers<void>()
    const probeHarnessAuth = vi.fn(() =>
      Effect.promise(async () => {
        await probe.promise
        return { state: "authenticated" as const, methods: [], canLogout: true }
      })
    )
    const manager = makeHarnessAuthManager({
      agents: fakeAgentRuntime({ probeHarnessAuth }),
      dataDir: directory,
      db,
      terminal: fakeTerminalManager(),
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

    await manager.decorateHarnesses([harness])
    const settling = manager.decorateHarnesses([harness], "settle")
    probe.resolve()

    expect((await settling)[0]).toMatchObject({ enabled: true, auth: { state: "authenticated" } })
    await manager.decorateHarnesses([harness], "settle")
    expect(probeHarnessAuth).toHaveBeenCalledOnce()
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
      agents: fakeAgentRuntime({ probeHarnessAuth }),
      dataDir: directory,
      db,
      terminal: fakeTerminalManager(),
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
    agents: fakeAgentRuntime(),
    terminal: fakeTerminalManager(),
    resolveEnv: async () => ({ HOME: directory }),
    sharedAccounts: () => fakeSharedAccounts({ reconcile: async () => {}, probe })
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
  expect((await manager.decorateHarnesses([harness], "force"))[0]).toMatchObject({
    enabled: true,
    auth: { activeAccountId: "shared-selected", state: "authenticated" }
  })
  expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])
  await manager.decorateHarnesses([harness], "force")
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
    agents: fakeAgentRuntime(),
    terminal: fakeTerminalManager(),
    resolveEnv: async () => ({ HOME: directory }),
    sharedAccounts: () => fakeSharedAccounts({ reconcile: async () => {}, logout })
  })
  const events: string[] = [],
    stop = manager.subscribe((event) => events.push(event.kind))
  expect(await manager.logout("shared-selected")).toMatchObject({ authState: "expired" })
  expect(events).toEqual(["harness.account.updated", "harness.auth.updated"])
  await manager.logout("shared-selected")
  expect(events).toHaveLength(2)
  stop()
})

it("emits auth events only when a probe changes what clients render", async () => {
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
    agents: fakeAgentRuntime({ probeHarnessAuth }),
    dataDir: directory,
    db,
    terminal: fakeTerminalManager(),
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
