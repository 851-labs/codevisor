import { Effect } from "effect"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { expect, it, vi } from "vitest"
import { defaultServerConfig, makeEventFanout, type RouteState } from "../server.js"
import { idleRestartCoordinator, makeServices, run, tempDirs } from "../test-support.js"
import { createSessionIfMissing } from "./session-workspace.js"

it("joins a pending session creation without starting another agent", async () => {
  const { agents, services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-pending-create-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const fanout = await run(makeEventFanout)
  const state: RouteState = {
    activePromptSessions: new Set(),
    activeTurnSessions: new Set(),
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map(),
    turnHeldSessions: new Set(),
    updateSignature: {},
    restartHeldSessions: new Set(),
    restart: idleRestartCoordinator()
  }
  const entered = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const joined = Promise.withResolvers<void>()
  const create = services.agents.createAgentSession
  vi.spyOn(services.agents, "createAgentSession").mockImplementation((...args) =>
    Effect.andThen(
      Effect.promise(async () => {
        entered.resolve()
        await release.promise
      }),
      create(...args)
    )
  )
  const get = state.pendingSessionCreates.get.bind(state.pendingSessionCreates)
  vi.spyOn(state.pendingSessionCreates, "get").mockImplementation((id) => {
    const pending = get(id)
    if (pending !== undefined) joined.resolve()
    return pending
  })
  const payload = {
    id: "client-session",
    projectId: project.id,
    harnessId: "codex",
    title: "Pending"
  }
  const first = createSessionIfMissing(
    services,
    fanout,
    state,
    defaultServerConfig({ id: "server-a" }),
    payload
  )
  await entered.promise
  const second = createSessionIfMissing(
    services,
    fanout,
    state,
    defaultServerConfig({ id: "server-a" }),
    payload
  )
  await joined.promise
  release.resolve()
  const [created, existing] = await Promise.all([first, second])
  expect(created.created).toBe(true)
  expect(existing.created).toBe(false)
  expect(created.session).toEqual(existing.session)
  expect(agents.creations).toEqual([["codex", folder]])
  expect(state.pendingSessionCreates.size).toBe(0)
})
