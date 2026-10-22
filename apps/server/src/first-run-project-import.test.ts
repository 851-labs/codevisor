import { mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { join } from "node:path"

import {
  AgentRuntimeError,
  type AgentRuntimeService,
  type AgentSessionSummary
} from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { importFirstRunProjects, startFirstRunProjectImport } from "./first-run-project-import.js"
import { defaultServerConfig } from "./server-config.js"
import { makeEventFanout } from "./server-context.js"
import { jsonRequest, listEvents, makeServices, run, startWithApp } from "./test-support.js"

const roots: Array<string> = []

beforeEach(() => {
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", join(makeRoot(), "managed"))
  vi.stubEnv("CODEVISOR_DEBUG", "1")
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true })
})

describe("first-run project import", () => {
  it("adds folders with recent chats from installed harnesses on a new server", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.setHarnessEnabled("opencode", false))

    await machine.importProjects()

    expect(await machine.projectFolders()).toEqual([machine.folders.recent, machine.folders.older])
    expect(machine.scannedHarnesses.toSorted()).toEqual(["claude-code", "codex"])
    expect(machine.agents.environmentRefreshes).toHaveLength(1)
    expect(machine.createdEvents()).toHaveLength(2)
    expect(await machine.marker()).toBe("done")
    expect(machine.statusEvents()).toEqual([
      { state: "running" },
      { state: "running", harnesses: foundHarnesses },
      { state: "running", harnesses: foundHarnesses, addedProjects: 1 },
      { state: "running", harnesses: foundHarnesses, addedProjects: 2 },
      { state: "done", harnesses: foundHarnesses, addedProjects: 2 }
    ])
    expect(machine.logs()).toEqual(
      expect.arrayContaining([
        `[first-run-projects] added ${machine.folders.recent} (1 chats, last ${machine.activity.recent})`,
        `[first-run-projects] skipped ${machine.folders.stale}: no chats in the last 7 days`,
        `[first-run-projects] skipped ${machine.home}: home folder or one of its parents`
      ])
    )
  })

  it("never runs again, so a deleted project stays deleted", async () => {
    const machine = await makeMachine()
    await machine.importProjects()
    const recent = (await run(machine.services.db.listProjects)).find(
      (project) => project.locations[0]!.folderPath === machine.folders.recent
    )
    await run(machine.services.db.deleteProject(recent!.id))
    machine.scannedHarnesses.length = 0

    await machine.importProjects()

    expect(await machine.projectFolders()).toEqual([machine.folders.older])
    expect(machine.scannedHarnesses).toEqual([])
  })

  it("leaves an existing install's projects untouched", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.setMachineSetting(FIRST_RUN_PROJECTS_SETTING, undefined))

    await machine.importProjects()

    expect(await machine.projectFolders()).toEqual([])
    expect(machine.scannedHarnesses).toEqual([])
    expect(await machine.marker()).toBeUndefined()
  })

  it("skips folders the user added as projects before the scan finished", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.createProject({ folderPath: machine.folders.recent }))

    await machine.importProjects()

    expect(await machine.projectFolders()).toEqual([machine.folders.recent, machine.folders.older])
    expect(machine.createdEvents()).toHaveLength(1)
    expect(machine.logs()).toContain(
      `[first-run-projects] skipped ${machine.folders.recent}: already inside a project`
    )
  })

  it("still scans when the shell environment cannot be resolved", async () => {
    const machine = await makeMachine({
      refreshEnvironment: Effect.fail(
        new AgentRuntimeError({ message: "no shell", operation: "refreshEnvironment" })
      )
    })

    await machine.importProjects()

    expect(await machine.projectFolders()).toEqual([machine.folders.recent, machine.folders.older])
  })

  it.each([
    { debug: "1", logged: ["[first-run-projects] failed: discovery failed"] },
    { debug: undefined, logged: [] }
  ])("keeps the run pending after a failure (CODEVISOR_DEBUG=$debug)", async (row) => {
    const machine = await makeMachine({
      discoverHarnesses: Effect.die(new Error("discovery failed"))
    })
    vi.stubEnv("CODEVISOR_DEBUG", row.debug)

    await startFirstRunProjectImport(machine.services, machine.fanout, machine.config)

    expect(machine.logs()).toEqual(row.logged)
    expect(await machine.marker()).toBe("pending")
    expect(machine.statusEvents().at(-1)).toEqual({ state: "failed" })
  })

  it("reports a failed run with the harnesses it had already found", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.setHarnessEnabled("opencode", false))
    const failing = {
      ...machine.services,
      db: { ...machine.services.db, createProject: () => Effect.die(new Error("disk full")) }
    }

    await startFirstRunProjectImport(failing, machine.fanout, machine.config)

    expect(machine.statusEvents().at(-1)).toEqual({ state: "failed", harnesses: foundHarnesses })
  })

  it("settles quietly when it cannot record any status", async () => {
    const machine = await makeMachine()
    const silent = {
      ...machine.services,
      db: { ...machine.services.db, appendEvent: () => Effect.die(new Error("read-only")) }
    }

    await expect(
      startFirstRunProjectImport(silent, machine.fanout, machine.config)
    ).resolves.toBeUndefined()
    expect(await machine.marker()).toBe("pending")
  })

  it("serves the first-run status from the run, or from the marker after a restart", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.setHarnessEnabled("opencode", false))
    const server = await startWithApp(machine.services, machine.fanout)
    expect((await jsonRequest(server, "/v1/first-run")).body).toEqual({ state: "running" })

    await machine.importProjects()
    expect((await jsonRequest(server, "/v1/first-run")).body).toEqual({
      state: "done",
      harnesses: foundHarnesses,
      addedProjects: 2
    })

    const restarted = await startWithApp({ ...machine.services }, machine.fanout)
    expect((await jsonRequest(restarted, "/v1/first-run")).body).toEqual({ state: "done" })
  })

  it("tells clients of an existing install that there is no first run", async () => {
    const machine = await makeMachine()
    await run(machine.services.db.setMachineSetting(FIRST_RUN_PROJECTS_SETTING, undefined))
    const server = await startWithApp(machine.services, machine.fanout)

    expect((await jsonRequest(server, "/v1/first-run")).body).toEqual({ state: "notApplicable" })
  })

  it("runs only on servers configured for it", async () => {
    const machine = await makeMachine()
    const unconfigured = defaultServerConfig({ bootId: "boot", id: "test" })

    await startFirstRunProjectImport(machine.services, machine.fanout, unconfigured)
    expect(machine.scannedHarnesses).toEqual([])

    await startFirstRunProjectImport(machine.services, machine.fanout, machine.config)
    expect(await machine.projectFolders()).toEqual([machine.folders.recent, machine.folders.older])
  })
})

const makeMachine = async (overrides: Partial<AgentRuntimeService> = {}) => {
  const home = makeRoot()
  const folders = {
    recent: makeFolder(home, "recent"),
    older: makeFolder(home, "older"),
    stale: makeFolder(home, "stale")
  }
  const activity = { recent: daysAgo(1), older: daysAgo(3), stale: daysAgo(10) }
  const sessions: ReadonlyArray<AgentSessionSummary> = [
    session(folders.recent, activity.recent),
    session(folders.older, activity.older),
    session(folders.stale, activity.stale),
    session(home, activity.recent)
  ]
  const scannedHarnesses: Array<string> = []
  const base = await makeServices()
  const agents = {
    ...base.agents,
    discoverHarnesses: Effect.succeed(fixtureHarnesses),
    listAgentSessions: (harnessId: string) =>
      Effect.sync((): ReadonlyArray<AgentSessionSummary> => {
        scannedHarnesses.push(harnessId)
        return harnessId === "codex" ? sessions : []
      }),
    ...overrides
  }
  const services = { ...base.services, agents }
  const fanout = await run(makeEventFanout)
  const config = defaultServerConfig({
    bootId: "boot",
    id: "test",
    firstRunProjects: { dataDirectory: makeFolder(home, "data"), homeDirectory: home }
  })
  const debug = vi.spyOn(console, "debug").mockImplementation(() => undefined)
  return {
    activity,
    agents,
    config,
    fanout,
    folders,
    home,
    scannedHarnesses,
    services,
    importProjects: () =>
      importFirstRunProjects(services, fanout, "test", config.firstRunProjects!),
    createdEvents: () => listEvents(services).filter((event) => event.kind === "project.created"),
    statusEvents: () =>
      listEvents(services)
        .filter((event) => event.kind === "firstRun.updated")
        .map((event) => event.payload),
    logs: () => debug.mock.calls.map(([message]) => String(message)),
    marker: () => run(services.db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING)),
    projectFolders: async () =>
      (await run(services.db.listProjects))
        .map((project) => project.locations[0]!.folderPath)
        .toSorted((left, right) => right.localeCompare(left))
  }
}

const harness = (id: string, state: "ready" | "unavailable"): Harness => ({
  id,
  name: id,
  symbolName: "terminal",
  source: "registry",
  launchKind: "npx",
  enabled: true,
  readiness: { state }
})

const foundHarnesses = [
  { id: "codex", name: "codex" },
  { id: "claude-code", name: "claude-code" }
]

const fixtureHarnesses: ReadonlyArray<Harness> = [
  harness("codex", "ready"),
  harness("claude-code", "ready"),
  harness("pi", "unavailable"),
  harness("opencode", "ready")
]

const session = (cwd: string, updatedAt: string): AgentSessionSummary => ({
  sessionId: cwd,
  cwd,
  updatedAt
})

const daysAgo = (days: number): string =>
  new Date(Date.now() - days * 24 * 60 * 60 * 1_000).toISOString()

const makeRoot = (): string => {
  const root = mkdtempSync(join(process.cwd(), ".first-run-projects-"))
  roots.push(root)
  return root
}

const makeFolder = (root: string, name: string): string => {
  const path = join(root, name)
  mkdirSync(path)
  return path
}
