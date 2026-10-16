import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { WorkspaceFileChanges } from "@codevisor/api"
import { Schema } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import { sessionEventSink } from "./session-events.js"
import { workspaceFiles } from "./workspace-files.js"

const roots: Array<string> = []

afterEach(() => {
  vi.useRealTimers()
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

const git = (cwd: string, ...args: Array<string>) =>
  execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.test", ...args], {
    cwd,
    stdio: "ignore"
  })

const makeRepo = () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-workspace-files-")))
  roots.push(root)
  const repo = join(root, "repo")
  mkdirSync(join(repo, "src"), { recursive: true })
  execFileSync("git", ["init", "-b", "main", repo], { stdio: "ignore" })
  writeFileSync(join(repo, "src", "app.ts"), "one\ntwo\n")
  writeFileSync(join(repo, "committed.ts"), "a\n")
  writeFileSync(join(repo, "shell.txt"), "x\n")
  writeFileSync(join(repo, "gone.txt"), "bye\n")
  git(repo, "add", ".")
  git(repo, "commit", "-m", "baseline")
  return { root, repo }
}

const at = (minute: number) => vi.setSystemTime(new Date(Date.UTC(2020, 0, 1, 12, minute)))

const editPayload = (
  toolCallId: string,
  diffStats: ReadonlyArray<{ path: string; added: number; removed: number }>
) => ({
  sessionUpdate: "tool_call_update",
  toolCallId,
  kind: "edit",
  status: "completed",
  diffStats
})

const fixture = async () => {
  const { services } = await makeServices("workspace-files")
  const fanout = await run(makeEventFanout)
  const project = await run(services.db.createProject({ folderPath: "/tmp/workspace-files" }))
  const workspace = async (fields: { rootDirectory?: string; isArchived?: boolean }) => {
    const created = await run(
      services.db.upsertWorkspace({
        projectId: project.id,
        name: "Work",
        hasCustomName: false,
        ...fields
      })
    )
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(services.db.setSessionWorkspace(session.id, created.id))
    const sink = sessionEventSink(services, fanout, "workspace-files", session.id)
    await sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnState: "started" }
    })
    const edit = async (
      minute: number,
      toolCallId: string,
      diffStats: ReadonlyArray<{ path: string; added: number; removed: number }>
    ) => {
      at(minute)
      await sink({
        kind: "session.output",
        subjectId: session.id,
        payload: editPayload(toolCallId, diffStats)
      })
    }
    return { workspace: created, session, edit }
  }
  const server = await startWithApp(services, fanout)
  const files = async (workspaceId: string) =>
    Schema.decodeUnknownSync(WorkspaceFileChanges)(
      (await jsonRequest(server, `/v1/workspaces/${workspaceId}/files`)).body
    )
  return { services, server, workspace, files }
}

describe("workspace files route", () => {
  it("merges agent edits with the checkout's uncommitted changes", async () => {
    const { repo } = makeRepo()
    const f = await fixture()
    vi.useFakeTimers({ toFake: ["Date"] })
    const work = await f.workspace({ rootDirectory: repo })
    await work.edit(1, "committed", [{ path: join(repo, "committed.ts"), added: 4, removed: 1 }])
    await work.edit(2, "relative", [{ path: "committed.ts", added: 1, removed: 0 }])
    await work.edit(3, "app", [
      { path: join(repo, "src", "app.ts"), added: 9, removed: 9 },
      { path: join(repo, "src", "new.ts"), added: 2, removed: 0 }
    ])
    await work.edit(4, "outside", [
      { path: "/elsewhere/memory.md", added: 3, removed: 0 },
      { path: "../escape.ts", added: 1, removed: 0 },
      { path: repo, added: 1, removed: 0 }
    ])
    vi.useRealTimers()
    writeFileSync(join(repo, "src", "app.ts"), "one\nchanged\nthree\n")
    writeFileSync(join(repo, "src", "new.ts"), "a\nb\n")
    writeFileSync(join(repo, "shell.txt"), "x\ny\n")
    rmSync(join(repo, "gone.txt"))

    const body = await f.files(work.workspace.id)
    expect(body.truncated).toBe(false)
    expect(body.files.map((file) => file.path)).toEqual([
      "shell.txt",
      "src/app.ts",
      "src/new.ts",
      "committed.ts",
      "gone.txt"
    ])
    const [shell, app, created, committed, gone] = body.files
    expect(shell).toMatchObject({ status: "modified", added: 1, removed: 0, uncommitted: true })
    expect(shell?.sessionId).toBeUndefined()
    expect(app).toEqual({
      path: "src/app.ts",
      added: 2,
      removed: 1,
      status: "modified",
      uncommitted: true,
      changedAt: "2020-01-01T12:03:00.000Z",
      sessionId: work.session.id
    })
    expect(created).toMatchObject({ status: "added", added: 2, removed: 0, uncommitted: true })
    expect(committed).toEqual({
      path: "committed.ts",
      added: 5,
      removed: 1,
      uncommitted: false,
      changedAt: "2020-01-01T12:02:00.000Z",
      sessionId: work.session.id
    })
    expect(gone).toEqual({
      path: "gone.txt",
      added: 0,
      removed: 1,
      status: "deleted",
      uncommitted: true
    })

    expect((await jsonRequest(f.server, "/v1/workspaces/missing/files")).status).toBe(404)
    expect(
      (await jsonRequest(f.server, `/v1/workspaces/${work.workspace.id}/files`, { method: "POST" }))
        .status
    ).toBe(404)
    expect((await jsonRequest(f.server, `/v1/workspaces/${work.workspace.id}/git`)).status).toBe(
      200
    )
  })

  it("reads agent edits without git when the checkout is linked, missing, archived or failing", async () => {
    const { root, repo } = makeRepo()
    const linked = join(root, "linked")
    symlinkSync(repo, linked)
    const f = await fixture()
    vi.useFakeTimers({ toFake: ["Date"] })

    const throughLink = await f.workspace({ rootDirectory: linked })
    await throughLink.edit(1, "real", [{ path: join(repo, "committed.ts"), added: 1, removed: 0 }])
    const rootless = await f.workspace({})
    await rootless.edit(2, "rootless", [
      { path: "notes.md", added: 2, removed: 0 },
      { path: join(repo, "committed.ts"), added: 1, removed: 0 }
    ])
    const archived = await f.workspace({
      rootDirectory: join(root, "archived-worktree"),
      isArchived: true
    })
    await archived.edit(3, "archived", [
      { path: join(root, "archived-worktree", "kept.ts"), added: 3, removed: 1 }
    ])
    vi.useRealTimers()
    writeFileSync(join(repo, "shell.txt"), "x\ny\n")

    expect((await f.files(throughLink.workspace.id)).files).toMatchObject([
      { path: "shell.txt", uncommitted: true },
      { path: "committed.ts", added: 1, uncommitted: false }
    ])
    expect(await f.files(rootless.workspace.id)).toEqual({
      files: [
        {
          path: "notes.md",
          added: 2,
          removed: 0,
          uncommitted: false,
          changedAt: "2020-01-01T12:02:00.000Z",
          sessionId: rootless.session.id
        }
      ],
      truncated: false
    })
    expect((await f.files(archived.workspace.id)).files).toMatchObject([
      { path: "kept.ts", added: 3, removed: 1, uncommitted: false }
    ])

    const failure = vi.spyOn(console, "error").mockImplementation(() => {})
    try {
      const failing = await workspaceFiles(
        { ...f.services, resolveGitEnvironment: () => Promise.reject(new Error("no git")) },
        "workspace-files",
        throughLink.workspace
      )
      expect(failing.files).toMatchObject([{ path: "committed.ts", uncommitted: false }])
      expect(failure).toHaveBeenCalledWith("Could not read workspace changes:", expect.any(Error))
    } finally {
      failure.mockRestore()
    }
  })
})
