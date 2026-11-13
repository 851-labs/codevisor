import { mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { join } from "node:path"

import type { AgentSessionSummary } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { answerFirstRunFolder } from "./first-run-folder-answers.js"
import { importFirstRunProjects, type FirstRun } from "./first-run-project-import.js"
import { readFirstRunStatus } from "./first-run-status.js"
import { defaultServerConfig } from "./server-config.js"
import { makeEventFanout } from "./server-context.js"
import { jsonRequest, makeServices, run, startWithApp, waitFor } from "./test-support.js"

describe("first-run projects in protected folders on a Mac", () => {
  it("adds projects elsewhere and asks about Documents and Desktop without reading them", async () => {
    const mac = await makeMac()

    await mac.importProjects()

    expect(await mac.projectNames()).toEqual(["tool"])
    expect(await mac.status()).toMatchObject({
      state: "done",
      projects: [{ name: "tool" }],
      folders: [
        { id: "documents", name: "Documents", projects: ["api", "web"] },
        { id: "desktop", name: "Desktop", projects: ["site"] }
      ]
    })
  })

  it("adds a folder's projects once the user allows it and macOS agrees", async () => {
    const mac = await makeMac()
    await mac.importProjects()

    await mac.answer("documents", "allow")

    expect(mac.probedFolders).toEqual([join(mac.home, "Documents")])
    expect(await mac.projectNames()).toEqual(["api", "tool", "web"])
    expect(await mac.status()).toMatchObject({
      projects: [{ name: "tool" }, { name: "web" }, { name: "api" }],
      folders: [{ id: "desktop" }]
    })
  })

  it("stays out of a folder the user declines, and one macOS refuses", async () => {
    const mac = await makeMac({ refuses: ["Documents"] })
    await mac.importProjects()

    await mac.answer("desktop", "decline")
    await mac.answer("documents", "allow")

    expect(mac.probedFolders).toEqual([join(mac.home, "Documents")])
    expect(await mac.projectNames()).toEqual(["tool"])
    expect((await mac.status()).folders).toBeUndefined()
  })

  it("still asks after the server restarts", async () => {
    const mac = await makeMac()
    await mac.importProjects()

    expect(await readFirstRunStatus({ ...mac.services })).toEqual({
      state: "done",
      folders: [
        {
          id: "documents",
          name: "Documents",
          path: join(mac.home, "Documents"),
          projects: ["api", "web"]
        },
        { id: "desktop", name: "Desktop", path: join(mac.home, "Desktop"), projects: ["site"] }
      ]
    })
  })

  it("answers over HTTP and turns away answers nobody is waiting for", async () => {
    const mac = await makeMac()
    await mac.importProjects()
    const server = await startWithApp(mac.services, mac.fanout, {
      id: "test",
      firstRunProjects: mac.firstRun.config
    })
    const answer = (folder: string, body: unknown) =>
      jsonRequest(server, `/v1/first-run/folders/${folder}`, {
        method: "POST",
        body: JSON.stringify(body)
      })

    expect((await answer("documents", { access: "maybe" })).status).toBe(400)
    expect((await answer("music", { access: "allow" })).status).toBe(404)
    expect((await answer("desktop", { access: "allow" })).status).toBe(200)

    await waitFor(async () => (await mac.projectNames()).includes("site"))
    expect((await answer("desktop", { access: "allow" })).status).toBe(404)
  })
})

const makeMac = async (options: { readonly refuses?: ReadonlyArray<string> } = {}) => {
  const home = mkdtempSync(join(process.cwd(), ".first-run-folders-"))
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", join(home, "managed"))
  onTestFinished(() => {
    vi.unstubAllEnvs()
    rmSync(home, { force: true, recursive: true })
  })
  const sessions: ReadonlyArray<AgentSessionSummary> = [
    session(makeFolder(home, "code", "tool"), 1),
    session(makeFolder(home, "Documents", "api"), 2),
    session(makeFolder(home, "Documents", "web"), 3),
    session(makeFolder(home, "Desktop", "site"), 4)
  ]
  const base = await makeServices()
  const agents = {
    ...base.agents,
    discoverHarnesses: Effect.succeed(harnesses),
    listAgentSessions: () => Effect.succeed(sessions)
  }
  const services = { ...base.services, agents }
  const fanout = await run(makeEventFanout)
  const probedFolders: Array<string> = []
  const refused = new Set((options.refuses ?? []).map((name) => join(home, name)))
  const config = defaultServerConfig({
    bootId: "boot",
    id: "test",
    firstRunProjects: {
      dataDirectory: makeFolder(home, "data"),
      homeDirectory: home,
      platform: "darwin",
      canReadFolder: (path) => {
        probedFolders.push(path)
        return Promise.resolve(!refused.has(path))
      }
    }
  })
  const firstRun: FirstRun = {
    services,
    fanout,
    serverId: "test",
    config: config.firstRunProjects!
  }
  return {
    fanout,
    firstRun,
    home,
    probedFolders,
    services,
    importProjects: () => importFirstRunProjects(services, fanout, "test", firstRun.config),
    answer: (folder: string, access: "allow" | "decline") =>
      answerFirstRunFolder(firstRun, folder, access),
    status: () => readFirstRunStatus(services),
    projectNames: async () =>
      (await run(services.db.listProjects)).map((project) => project.name).toSorted()
  }
}

const codex: Harness = {
  id: "codex",
  name: "Codex",
  symbolName: "terminal",
  source: "registry",
  launchKind: "npx",
  enabled: true,
  readiness: { state: "ready" }
}

const harnesses: ReadonlyArray<Harness> = [codex]

const session = (cwd: string, hoursAgo: number): AgentSessionSummary => ({
  sessionId: cwd,
  cwd,
  updatedAt: new Date(Date.now() - hoursAgo * 60 * 60 * 1_000).toISOString()
})

const makeFolder = (root: string, ...names: ReadonlyArray<string>): string => {
  const path = join(root, ...names)
  mkdirSync(path, { recursive: true })
  return path
}
