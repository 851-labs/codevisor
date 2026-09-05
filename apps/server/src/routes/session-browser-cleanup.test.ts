import { describe, expect, it, vi } from "vitest"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeServices, run, tempDirs } from "../test-support.js"
import { makeEventFanout } from "../server.js"
import type { CodevisorServerServices } from "../server-context.js"
import { sessionEventSink } from "./session-events.js"

const fixture = async () => {
  const { services } = await makeServices("browser-cleanup")
  const folderPath = mkdtempSync(join(tmpdir(), "browser-cleanup-"))
  tempDirs.push(folderPath)
  const project = await run(services.db.createProject({ folderPath }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "codex" })
  )
  const fanout = await run(makeEventFanout)
  const sink = sessionEventSink(
    services as unknown as CodevisorServerServices,
    fanout,
    "browser-cleanup",
    session.id
  )
  const ended = () =>
    sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnState: "ended", stopReason: "end_turn" }
    })
  const events = async () =>
    (await run(services.db.listSubjectEvents(session.id))).filter(
      (event) => event.kind === "session.updated"
    )
  return { services, session, ended, events }
}

describe("browser cleanup at turn completion", () => {
  it("finishes tab cleanup before persisting the turn end", async () => {
    const { services, session, ended, events } = await fixture()
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const cleanup = vi.spyOn(services.mcp, "finishTurn").mockImplementation(async () => {
      entered.resolve()
      await release.promise
    })
    const completion = Promise.resolve(ended())
    try {
      await entered.promise
      expect(await events()).toEqual([])
      expect(cleanup).toHaveBeenCalledWith(session.id)
    } finally {
      release.resolve()
      await completion
      cleanup.mockRestore()
    }
    expect(await events()).toEqual([
      expect.objectContaining({ payload: expect.objectContaining({ turnState: "ended" }) })
    ])
  })

  it.each([new Error("extension disconnected"), "extension disconnected"])(
    "preserves turn completion when cleanup fails: %s",
    async (cause) => {
      const { services, ended, events } = await fixture()
      const cleanup = vi.spyOn(services.mcp, "finishTurn").mockRejectedValue(cause)
      const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
      try {
        await ended()
        expect(await events()).toEqual([
          expect.objectContaining({ payload: expect.objectContaining({ turnState: "ended" }) })
        ])
        expect(errors).toHaveBeenCalledWith(expect.stringContaining("extension disconnected"))
      } finally {
        cleanup.mockRestore()
        errors.mockRestore()
      }
    }
  )
})
