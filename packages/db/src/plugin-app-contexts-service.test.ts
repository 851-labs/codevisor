import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run } from "./test-support.js"

const fixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/plugin-app-contexts" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { db, session }
}

const update = (sessionId: string, viewId: string, context: Record<string, unknown>) => ({
  sessionId,
  viewId,
  plugin: "Zillow",
  tool: "zillow_property_search",
  context
})

describe("plugin app contexts", () => {
  it("keeps the latest context per view and ignores identical updates", async () => {
    const { db, session } = await fixture()

    await run(db.savePluginAppContext(update(session.id.toUpperCase(), "view-1", { a: 1 })))
    await run(db.savePluginAppContext(update(session.id, "view-1", { a: 1 })))
    await run(db.savePluginAppContext(update(session.id, "view-2", { b: 1 })))
    await run(db.savePluginAppContext(update(session.id, "view-1", { a: 2 })))

    expect(await run(db.listPluginAppContexts(session.id.toUpperCase()))).toEqual([
      {
        sessionId: session.id,
        viewId: "view-1",
        plugin: "Zillow",
        tool: "zillow_property_search",
        context: { a: 2 },
        revision: 2,
        updatedAt: expect.any(String)
      },
      expect.objectContaining({ viewId: "view-2", context: { b: 1 }, revision: 1 })
    ])
  })

  it("clears only the revisions that were delivered", async () => {
    const { db, session } = await fixture()
    await run(db.savePluginAppContext(update(session.id, "view-1", { a: 1 })))
    await run(db.savePluginAppContext(update(session.id, "view-2", { b: 1 })))
    const delivered = await run(db.listPluginAppContexts(session.id))
    await run(db.savePluginAppContext(update(session.id, "view-2", { b: 2 })))

    await run(
      db.clearPluginAppContexts(
        session.id.toUpperCase(),
        delivered.map(({ viewId, revision }) => ({ viewId, revision }))
      )
    )

    expect(await run(db.listPluginAppContexts(session.id))).toEqual([
      expect.objectContaining({ viewId: "view-2", context: { b: 2 }, revision: 2 })
    ])
  })

  it("refuses contexts for sessions that don't exist", async () => {
    const { db } = await fixture()

    await expect(
      run(db.savePluginAppContext(update("4c3b4c84-6c8e-4a0a-8e7e-4f5f0d3b0e11", "view-1", {})))
    ).rejects.toThrow()
  })
})
