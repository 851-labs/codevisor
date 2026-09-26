import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CodevisorDatabaseService } from "@codevisor/db"
import { describe, expect, it } from "vitest"

import { makeEventFanout } from "../server.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { waitForSessions } from "./session-wait.js"

const fixture = async () => {
  // The server id must match the database's so the project folder is local.
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const server = await startWithApp(services, fanout)
  runningServers.push(server)
  const folderPath = mkdtempSync(join(tmpdir(), "codevisor-wait-"))
  tempDirs.push(folderPath)
  const project = await run(services.db.createProject({ folderPath }))
  const session = async () =>
    run(services.db.createSession({ projectId: project.id, harnessId: "codex" }))
  const wait = (body: unknown) =>
    jsonRequest(server, "/v1/sessions/wait", { method: "POST", body: JSON.stringify(body) })
  // A database whose first per-session read announces that the wait has
  // validated its ids and subscribed, so a test can change state strictly
  // after the wait began.
  const observedDatabase = () => {
    const began = Promise.withResolvers<void>()
    const db: CodevisorDatabaseService = {
      ...services.db,
      getSessionSummary: (id) => {
        began.resolve()
        return services.db.getSessionSummary(id)
      }
    }
    return { db, began: began.promise }
  }
  return { agents, fanout, observedDatabase, server, services, session, wait }
}

describe("waiting for sessions", () => {
  it("answers at once when any session already matches, with its blocking question", async () => {
    const { services, session, wait } = await fixture()
    const idle = await session()
    const asking = await session()
    const question = {
      sessionUpdate: "question",
      questionId: "q1",
      questions: [{ id: "go", question: "Continue?", options: [{ label: "Yes" }] }]
    }
    await run(services.db.appendEvent("session.output", asking.id, question))

    expect(await wait({ ids: [asking.id.toUpperCase()], until: ["waitingForUser"] })).toEqual({
      status: 200,
      body: {
        sessions: [
          {
            id: asking.id,
            sidebarState: "waitingForUser",
            actionRequiredKind: "question",
            pendingQuestion: expect.objectContaining({ questionId: "q1" })
          }
        ],
        timedOut: false
      }
    })
    // The first match ends the wait; every listed session is still reported.
    expect(await wait({ ids: [idle.id, asking.id] })).toMatchObject({
      body: {
        sessions: [
          { id: idle.id, sidebarState: "idle" },
          { id: asking.id, sidebarState: "waitingForUser" }
        ],
        timedOut: false
      }
    })
  })

  it("does not treat a session with a prompt still queued as idle, and times out with current states", async () => {
    const { services, session, wait } = await fixture()
    const queued = await session()
    // Accepted but not yet dispatched: the row still reads idle.
    await run(services.db.createPromptQueueItem(queued.id, "next task"))
    expect(await wait({ ids: [queued.id], timeoutMs: 0 })).toEqual({
      status: 200,
      body: { sessions: [{ id: queued.id, sidebarState: "idle" }], timedOut: true }
    })
  })

  it("wakes when a watched turn finishes", async () => {
    const { agents, fanout, observedDatabase, server, session } = await fixture()
    const busy = await session()
    await jsonRequest(server, `/v1/sessions/${busy.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "slow prompt" })
    })
    await waitFor(() => agents.prompts.length === 1)
    const { db, began } = observedDatabase()
    const waiting = waitForSessions(db, fanout, { ids: [busy.id] }, new AbortController().signal)
    await began
    agents.releasePrompt()
    const result = await waiting
    expect(result.timedOut).toBe(false)
    // A finished turn nobody has read yet is "unread", which satisfies idle.
    expect(result.sessions).toEqual([{ id: busy.id, sidebarState: "unread" }])
  })

  it("wakes when a watched session is deleted and omits it", async () => {
    const { fanout, observedDatabase, server, session } = await fixture()
    const doomed = await session()
    const { db, began } = observedDatabase()
    const waiting = waitForSessions(
      db,
      fanout,
      { ids: [doomed.id], until: ["errored"] },
      new AbortController().signal
    )
    await began
    await jsonRequest(server, `/v1/sessions/${doomed.id}`, { method: "DELETE" })
    expect(await waiting).toEqual({ sessions: [], timedOut: false })
  })

  it("rejects empty and unknown ids", async () => {
    const { wait } = await fixture()
    expect(await wait({ ids: [] })).toMatchObject({ status: 400 })
    expect(await wait({ ids: ["missing"] })).toEqual({
      status: 404,
      body: { error: "Session not found: missing" }
    })
  })
})

describe("finding an orchestrator's work", () => {
  it("filters sessions by parent and labels", async () => {
    const { server, session } = await fixture()
    const parent = await session()
    const create = async (body: Record<string, unknown>) =>
      (
        (await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({ projectId: parent.projectId, harnessId: "codex", ...body })
        })) as { readonly body: { readonly id: string } }
      ).body.id
    const worker = await create({
      parentSessionId: parent.id,
      labels: { role: "worker", issue: "851-1" }
    })
    const reviewer = await create({ parentSessionId: parent.id, labels: { role: "reviewer" } })
    const ids = async (query: string) =>
      ((await jsonRequest(server, `/v1/sessions${query}`)).body as ReadonlyArray<{ id: string }>)
        .map((candidate) => candidate.id)
        .toSorted()

    expect(await ids(`?parentSessionId=${parent.id.toUpperCase()}`)).toEqual(
      [worker, reviewer].toSorted()
    )
    expect(await ids("?label=role=worker")).toEqual([worker])
    expect(await ids("?label=role&label=issue=851-1")).toEqual([worker])
    expect(await ids("?label=role=nobody")).toEqual([])
    expect(await jsonRequest(server, "/v1/sessions?label==worker")).toMatchObject({
      status: 400
    })

    expect(
      await jsonRequest(server, `/v1/sessions/${reviewer}`, {
        method: "PATCH",
        body: JSON.stringify({ labels: { role: "worker" } })
      })
    ).toMatchObject({ body: { labels: { role: "worker" } } })
    expect(await ids("?label=role=worker")).toEqual([worker, reviewer].toSorted())
  })

  it("filters workspaces by label", async () => {
    const { server, session } = await fixture()
    const { projectId } = await session()
    const put = (id: string, labels?: Record<string, string>) =>
      jsonRequest(server, `/v1/workspaces/${id}`, {
        method: "PUT",
        body: JSON.stringify({ projectId, name: id, hasCustomName: true, labels })
      })
    const labeled = "0b2d6a47-5d0f-4c77-9bfa-4f3b1f7f0a01"
    await put(labeled, { batch: "a" })
    await put("0b2d6a47-5d0f-4c77-9bfa-4f3b1f7f0a02")
    expect(
      (
        (await jsonRequest(server, "/v1/workspaces?label=batch=a")).body as ReadonlyArray<{
          id: string
        }>
      ).map((workspace) => workspace.id)
    ).toEqual([labeled])
  })
})
