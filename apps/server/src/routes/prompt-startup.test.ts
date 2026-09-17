import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { expect, it, vi } from "vitest"

import { makeEventFanout, type RouteState } from "../server.js"
import { idleRestartCoordinator, makeServices, run, tempDirs } from "../test-support.js"
import { drainPromptQueue } from "./prompt-queue.js"

it.each([false, true])(
  "history remains in progress during harness startup (failure=%s)",
  async (fails) => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-prompt-startup-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex", agentSessionId: "" })
    )
    const queued = await run(services.db.createPromptQueueItem(session.id, "Hello"))
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
    const create = agents.createAgentSession
    const spy = vi.spyOn(agents, "createAgentSession").mockImplementation((...args) =>
      Effect.andThen(
        Effect.promise(async () => {
          entered.resolve()
          await release.promise
          if (fails) throw new Error("Harness failed to start")
        }),
        create(...args)
      )
    )
    const drain = drainPromptQueue(services, fanout, state, "server-a", session.id)
    try {
      await Promise.race([
        entered.promise,
        drain.then(() => {
          throw new Error("Prompt drain ended before entering harness startup")
        })
      ])
      const starting = await run(services.db.getTranscriptPage(session.id, undefined, 8))
      expect(starting.items).toMatchObject([
        { role: "user", messageId: queued.id, text: "Hello" },
        { role: "assistant", isGenerating: true, text: "" }
      ])
      expect((await run(services.db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
      expect(agents.prompts).toEqual([])
      release.resolve()
      await drain
      const finished = await run(services.db.getTranscriptPage(session.id, undefined, 8))
      expect(finished.items.map((item) => item.id)).toEqual(starting.items.map((item) => item.id))
      expect(finished.items.at(-1)).toMatchObject({ role: "assistant", isGenerating: false })
      if (fails) expect(finished.items.at(-1)?.stopDetail).toContain("Harness failed to start")
      expect(await run(services.db.listProcessingPromptQueue(session.id))).toEqual([])
    } finally {
      release.resolve()
      await drain
      spy.mockRestore()
    }
  }
)
