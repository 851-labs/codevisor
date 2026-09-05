import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { setUpWorkspace, createFirstSession } from "./session-test-support.js"

describe("sessions routes", () => {
  it("deleting a workspace's last session deletes the workspace too", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-cascade-project-"))
    tempDirs.push(folder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/cascade-ws", {
      body: JSON.stringify({ projectId: project.id, name: "Cascade", hasCustomName: false }),
      method: "PUT"
    })
    const makeSession = async () =>
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: project.id,
            harnessId: "codex",
            workspaceId: "cascade-ws"
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
    const first = await makeSession()
    const second = await makeSession()

    // Deleting one of two: the workspace survives.
    expect(
      (await jsonRequest(server, `/v1/sessions/${first.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(await run(services.db.listWorkspaces)).toHaveLength(1)

    // Deleting the LAST session cascades to the workspace, with the event
    // clients rely on to drop it from their sidebars.
    expect(
      (await jsonRequest(server, `/v1/sessions/${second.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(await run(services.db.listWorkspaces)).toHaveLength(0)
    const events = await run(services.db.listEvents(0))
    expect(events.some((event) => event.kind === "workspace.deleted")).toBe(true)
  })

  it("opens a session in one round-trip, creating project and session only when missing", async () => {
    const { agents, server, services } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-open-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)

    // First open: nothing exists server-side — both records are created and
    // the first transcript page comes back, all in one request.
    const opened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        transcriptLimit: 8
      }),
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(opened.body).toMatchObject({
      session: { id: "open-session-1", projectId: "open-project-1", title: "Open flow" },
      transcript: { hasMore: false, items: [], pendingPlanApproval: false }
    })
    expect(agents.creations).toEqual([["codex", workspaceFolder]])

    await run(
      services.db.appendEvent("session.output", "open-session-1", {
        sessionUpdate: "plan",
        entries: [{ content: "Implement", priority: "medium", status: "in_progress" }]
      })
    )

    const unchanged = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        session: { harnessId: "codex", projectId: "open-project-1" }
      }),
      method: "POST"
    })
    expect(unchanged.status).toBe(200)
    expect(unchanged.body).toMatchObject({
      session: { title: "Open flow" },
      transcript: {
        sessionPlan: {
          entries: [{ content: "Implement", priority: "medium", status: "in_progress" }]
        }
      }
    })

    // Archive the project, then re-open with the original (now stale)
    // snapshot: the existing project must NOT be reverted to unarchived, the
    // session must not be re-created, and the update payload applies.
    await jsonRequest(server, "/v1/projects/open-project-1", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    const reopened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        update: { title: "Renamed on open" }
      }),
      method: "POST"
    })
    expect(reopened.status).toBe(200)
    expect(reopened.body).toMatchObject({ session: { title: "Renamed on open" } })
    expect(agents.creations).toHaveLength(1)
    const projects = (await jsonRequest(server, "/v1/projects")).body as ReadonlyArray<{
      readonly id: string
      readonly isArchived: boolean
    }>
    expect(projects.find((candidate) => candidate.id === "open-project-1")?.isArchived).toBe(true)

    // A body/path session-id mismatch is rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/other-id/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "open-session-1", projectId: "open-project-1" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // Invalid transcript limits are rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/open-session-1/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", projectId: "open-project-1" },
            transcriptLimit: 0
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // An open naming an unknown project with no project payload still 404s.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/orphan-session/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "orphan-session", projectId: "missing-project" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("treats differently-cased session ids as one session instead of minting a case-twin", async () => {
    const { server } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-case-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)

    // A chat created by a Node client stores the canonical lowercase uuid.
    const lowerId = "ab12cd34-ef56-4789-a012-3456789abcde"
    const upperId = lowerId.toUpperCase()
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder, id: "case-project" }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const created = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: lowerId,
        projectId: project.id,
        harnessId: "codex",
        title: "Created remotely"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)

    // Opening it with Swift's uppercase rendering must return the existing
    // row — this exact path used to insert a case-twin duplicate session,
    // which every client then showed as a second sidebar entry.
    const opened = await jsonRequest(server, `/v1/sessions/${upperId}/open`, {
      body: JSON.stringify({
        session: {
          harnessId: "codex",
          id: upperId,
          projectId: project.id.toUpperCase(),
          title: "Created remotely"
        }
      }),
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(opened.body).toMatchObject({ session: { id: lowerId, title: "Created remotely" } })

    // Updates addressed with the uppercase id land on the same single row.
    const renamed = await jsonRequest(server, `/v1/sessions/${upperId}`, {
      body: JSON.stringify({ title: "Renamed from the Mac" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    const sessions = (await jsonRequest(server, "/v1/sessions")).body as ReadonlyArray<{
      readonly id: string
      readonly title: string
    }>
    const twins = sessions.filter((session) => session.id.toLowerCase() === lowerId)
    expect(twins).toHaveLength(1)
    expect(twins[0]).toMatchObject({ id: lowerId, title: "Renamed from the Mac" })
  })

  it("creates sessions with harness titles, deferred and concurrent creation, and lookups", async () => {
    const { agents, server, workspace, workspaceFolder } = await setUpWorkspace()
    const session = await createFirstSession(server, workspace)
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "  Harness-generated title  " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    // Repeating the current harness title is an idempotent no-op.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Harness-generated title"
      }
    })
    // A missing/blank harness title keeps the existing first-prompt fallback.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "   " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ title: "User-provided title" }),
      method: "PATCH"
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Later harness-generated title"
      }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "User-provided title" }
    })
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: session.id,
            projectId: workspace.id,
            harnessId: "codex",
            title: "First chat"
          }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ agentSessionId: "agent-codex-codevisor", id: session.id })

    const deferredResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: workspace.id,
        harnessId: "codex",
        title: "Deferred chat",
        deferAgentSession: true
      }),
      method: "POST"
    })
    const deferred = deferredResponse.body as {
      readonly id: string
      readonly agentSessionId?: string
    }
    expect(deferred.agentSessionId).toBe("")
    expect(agents.creations).toEqual([["codex", workspaceFolder]])
    await jsonRequest(server, `/v1/sessions/${deferred.id}/prompt`, {
      body: JSON.stringify({ text: "hello deferred" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello deferred"))
    const deferredDetail = (await jsonRequest(server, `/v1/sessions/${deferred.id}`)).body as {
      readonly session: { readonly agentSessionId?: string }
    }
    expect(deferredDetail.session.agentSessionId).toBe("agent-codex-codevisor")
    expect(agents.prompts).toContainEqual(["agent-codex-codevisor", "hello deferred"])

    const concurrentSessionBody = JSON.stringify({
      id: "client-session-concurrent",
      projectId: workspace.id,
      harnessId: "codex",
      title: "Concurrent chat"
    })
    const workspaceCreationsBeforeConcurrent = agents.creations.filter(
      (creation) => creation[1] === workspaceFolder
    ).length
    const [firstConcurrent, secondConcurrent] = await Promise.all([
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      }),
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      })
    ])
    expect([firstConcurrent.status, secondConcurrent.status].sort()).toEqual([200, 201])
    expect(firstConcurrent.body).toMatchObject({
      agentSessionId: "agent-codex-codevisor",
      id: "client-session-concurrent"
    })
    expect(secondConcurrent.body).toEqual(firstConcurrent.body)
    expect(agents.creations.filter((creation) => creation[1] === workspaceFolder)).toHaveLength(
      workspaceCreationsBeforeConcurrent + 1
    )

    expect(await jsonRequest(server, "/v1/sessions")).toMatchObject({
      body: expect.arrayContaining([expect.objectContaining({ id: session.id })])
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { id: session.id }
    })
    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
    expect((await jsonRequest(server, "/v1/sessions/missing/branch-diff")).status).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: "client-session-id",
            projectId: "missing",
            harnessId: "codex"
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    const missingWorkspaceResponse = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({
        folderPath: "/tmp/codevisor-missing-session-workspace",
        id: "missing-folder-workspace"
      }),
      method: "POST"
    })
    expect(missingWorkspaceResponse.status).toBe(201)
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "missing-folder-workspace",
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).toEqual({
      body: { error: "Project folder does not exist: /tmp/codevisor-missing-session-workspace" },
      status: 400
    })
    expect((await jsonRequest(server, "/v1/sessions/missing")).status).toBe(500)
  })
})
