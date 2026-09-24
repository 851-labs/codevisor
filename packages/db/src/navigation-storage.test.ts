import type { EventEnvelope, NavigationDelta } from "@codevisor/api"
import { expect, it } from "vitest"

import { materializeNavigationDelta } from "./navigation-delta.js"
import { createServiceContext } from "./service-context.js"
import { memoryDatabase, run } from "./test-support.js"

it("hydrates persisted runtime configuration and selects only durable work for resume", async () => {
  const { db, sqlite, session } = await memoryDatabase()
  expect(await run(db.getSessionRuntimeState(session.id))).toEqual({
    sessionId: session.id,
    configOptions: []
  })
  sqlite
    .prepare("update sessions set agent_session_id = 'provider-id' where id = ?")
    .run(session.id)
  await run(
    db.saveSessionRuntimeState(session.id, {
      modes: { availableModes: [], currentModeId: "old" },
      configOptions: ["initial"]
    })
  )
  expect(await run(db.getSessionRuntimeState(session.id))).toMatchObject({
    sessionId: "provider-id",
    modes: { currentModeId: "old" },
    configOptions: ["initial"]
  })
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "current_mode_update",
      currentModeId: "new"
    })
  )
  await run(db.appendEvent("session.updated", session.id, { configOptions: ["updated"] }))
  expect(await run(db.getSessionRuntimeState(session.id))).toMatchObject({
    modes: { currentModeId: "new" },
    configOptions: ["updated"]
  })
  expect(await run(db.listSessionsRequiringResume)).toEqual([])
  await run(db.appendEvent("session.updated", session.id, { goal: { status: "active" } }))
  expect(await run(db.listSessionsRequiringResume)).toEqual([session.id])
  // Archive lives on the workspace now: a chat is skipped for resume because
  // the workspace holding it is archived, never because of its own state.
  const workspace = await run(
    db.upsertWorkspace({ projectId: session.projectId, name: "work", hasCustomName: false })
  )
  await run(db.setSessionWorkspace(session.id, workspace.id))
  expect(await run(db.listSessionsRequiringResume)).toEqual([session.id])
  await run(db.updateWorkspace(workspace.id, { isArchived: true }))
  expect(await run(db.listSessionsRequiringResume)).toEqual([])
})

it("coalesces navigation entity upserts and deletions and rejects unusable or oversized deltas", async () => {
  const { db, sqlite, config, session, project } = await memoryDatabase()
  const context = createServiceContext(sqlite, config)
  const event = (id: number, table: unknown, subjectId: string, payload = {}): EventEnvelope => ({
    id,
    serverId: "local",
    kind: "navigation.changed",
    subjectId,
    createdAt: "2026-09-16",
    payload: { table, ...payload }
  })
  const materialize = (events: EventEnvelope[]) =>
    materializeNavigationDelta(context, { events, cursor: 99, requiresSnapshot: false })
  sqlite
    .prepare(
      "insert into workspaces (id, server_id, project_id, name, created_at, sidebar_position) values ('workspace', 'local', ?, 'Workspace', '2026-09-16', 'a')"
    )
    .run(project.id)
  sqlite
    .prepare(
      "insert into workspace_panes (id, workspace_id, provider_id, pane_type, title, created_at) values ('pane', 'workspace', 'core', 'chat', 'Chat', '2026-09-16')"
    )
    .run()
  const delta = materialize([
    event(1, "project_locations", "location", { projectId: project.id }),
    event(2, "session_attention", session.id),
    event(3, "session_read_state", session.id),
    event(4, "workspaces", "workspace"),
    event(5, "workspace_panes", "pane"),
    { ...event(6, "sessions", session.id), kind: "session.updated" }
  ])
  expect(delta.events.map((e) => e.id)).toEqual([5, 6])
  expect(delta.events[0]!.payload).toMatchObject({
    projects: [{ id: project.id }],
    sessions: [{ id: session.id }],
    workspaces: [{ id: "workspace" }],
    panes: [{ id: "pane" }]
  })
  const deleted = materialize(
    ["projects", "sessions", "workspaces", "workspace_panes"].map((table, index) =>
      event(index, table, "gone")
    )
  )
  expect((deleted.events[0]!.payload as NavigationDelta).deleted).toHaveLength(4)
  expect(materialize([event(1, null, "bad")]).requiresSnapshot).toBe(true)
  expect(materialize([event(1, "project_locations", "bad")]).requiresSnapshot).toBe(true)
  expect(
    (materialize([event(1, "projects", project.id)]).events[0]!.payload as NavigationDelta).sessions
  ).toEqual([])
  sqlite
    .prepare("update sessions set title = ? where id = ?")
    .run("x".repeat(512 * 1024), session.id)
  expect(materialize([event(1, "sessions", session.id)]).requiresSnapshot).toBe(true)
  sqlite.prepare("update sessions set title = 'Chat' where id = ?").run(session.id)
  const location = (await run(db.listProjects))[0]!.locations[0]!
  await run(db.setProjectLocationGitState(location.id, true))
  expect((await run(db.getNavigationSnapshot)).projects[0]!.locations[0]!.isGitRepository).toBe(
    true
  )
  sqlite.prepare("delete from project_locations where project_id = ?").run(project.id)
  const snapshot = await run(db.getNavigationSnapshot)
  expect(snapshot.projects[0]!.locations).toEqual([])
  expect(snapshot.sessions[0]!.cwd).toBeUndefined()
  expect(
    (materialize([event(1, "sessions", session.id)]).events[0]!.payload as NavigationDelta).sessions
  ).toHaveLength(1)
})
