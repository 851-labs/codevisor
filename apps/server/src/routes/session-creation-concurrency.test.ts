import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { expect, it, vi } from "vitest"

import { defaultServerConfig, makeEventFanout, type RouteState } from "../server.js"
import { idleRestartCoordinator, makeServices, run, tempDirs } from "../test-support.js"
import { createSessionIfMissing } from "./session-workspace.js"

it.each(["project lookup", "agent creation"])(
  "joins a pending creation during %s",
  async (heldAt) => {
    const { agents, services: originalServices } = await makeServices("server-a")
    let services = originalServices
    const folder = mkdtempSync(join(tmpdir(), "codevisor-pending-create-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const fanout = await run(makeEventFanout)
    const state: RouteState = {
      activePromptSessions: new Set(),
      promptTurnReleases: new Map(),
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
    const hold = Effect.promise(async () => {
      entered.resolve()
      await release.promise
    })
    if (heldAt === "project lookup") {
      const list = services.db.listProjects
      services = { ...services, db: { ...services.db, listProjects: Effect.andThen(hold, list) } }
    } else {
      const create = services.agents.createAgentSession
      vi.spyOn(services.agents, "createAgentSession").mockImplementation((...args) =>
        Effect.andThen(hold, create(...args))
      )
    }
    let checks = 0
    const get = state.pendingSessionCreates.get.bind(state.pendingSessionCreates)
    vi.spyOn(state.pendingSessionCreates, "get").mockImplementation((id) => {
      const pending = get(id)
      if (++checks === 2) joined.resolve()
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
      defaultServerConfig({ bootId: "test-boot", id: "server-a" }),
      payload
    )
    await entered.promise
    const second = createSessionIfMissing(
      services,
      fanout,
      state,
      defaultServerConfig({ bootId: "test-boot", id: "server-a" }),
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
  }
)
