import { execFileSync } from "node:child_process"
import { existsSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeEventFanout, type RouteState } from "../server.js"
import { jsonRequest, run, start, tempDirs, idleRestartCoordinator } from "../test-support.js"
import { drainPromptQueue } from "./prompt-queue.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

const setup = async () => {
  const fixture = await start()
  const folder = mkdtempSync(join(tmpdir(), "codevisor-workspace-cleanup-"))
  tempDirs.push(folder)
  await jsonRequest(fixture.server, "/v1/projects", {
    method: "POST",
    body: JSON.stringify({ id: "project", folderPath: folder })
  })
  return { ...fixture, folder }
}

describe("workspace process cleanup", () => {
  for (const deferred of [true, false]) {
    it(`retires an agent when archive races its ${deferred ? "first" : "resumed"} load`, async () => {
      const { server, services } = await setup()
      await jsonRequest(server, "/v1/workspaces/work", {
        method: "PUT",
        body: JSON.stringify({ projectId: "project", name: "Work", hasCustomName: false })
      })
      await jsonRequest(server, "/v1/sessions", {
        method: "POST",
        body: JSON.stringify({
          id: "chat",
          projectId: "project",
          workspaceId: "work",
          harnessId: "codex",
          deferAgentSession: deferred
        })
      })
      vi.spyOn(services.agents, "loadAgentSession").mockImplementation((_harness, id) =>
        Effect.gen(function* () {
          yield* services.db.updateWorkspace("work", { isArchived: true }).pipe(Effect.orDie)
          return { sessionId: id, configOptions: [] }
        })
      )
      const closed = vi.spyOn(services.agents, "closeAgentSession").mockReturnValue(Effect.void)
      await expect(
        ensureAgentSessionFor(services, await run(makeEventFanout), "server-a", "chat")
      ).rejects.toThrow("archived while starting")
      await expect(
        ensureAgentSessionFor(services, await run(makeEventFanout), "server-a", "chat")
      ).rejects.toThrow("Restore the workspace")
      expect(closed).toHaveBeenCalledOnce()
    })
  }

  it("holds queued prompts after archive and checks workspace state after reading session state", async () => {
    const { server, services, folder } = await setup()
    await jsonRequest(server, "/v1/workspaces/work", {
      method: "PUT",
      body: JSON.stringify({ projectId: "project", name: "Work", hasCustomName: false })
    })
    await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({
        id: "chat",
        workspaceId: "work",
        projectId: "project",
        harnessId: "codex",
        deferAgentSession: true
      })
    })
    const panes = services.db.listWorkspacePanes
    Object.assign(services.db, {
      listWorkspacePanes: panes.pipe(
        Effect.tap(() => services.db.updateWorkspace("work", { isArchived: true }))
      )
    })
    try {
      expect(
        (
          await jsonRequest(server, "/v1/terminals", {
            method: "POST",
            body: JSON.stringify({ sessionId: "chat:terminal", cwd: folder, cols: 80, rows: 24 })
          })
        ).status
      ).toBe(409)
    } finally {
      Object.assign(services.db, { listWorkspacePanes: panes })
    }
    await run(services.db.createPromptQueueItem("chat", "Do not start"))
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
    const prompt = vi.spyOn(services.agents, "prompt")
    await drainPromptQueue(services, await run(makeEventFanout), state, "server-a", "chat")
    expect(prompt).not.toHaveBeenCalled()
    expect(await run(services.db.listPromptQueue("chat"))).toHaveLength(1)
  })
  {
    it("rejects a terminal whose workspace is archived during spawn", async () => {
      const { server, services, spawner, folder } = await setup()
      await jsonRequest(server, "/v1/workspaces/work", {
        method: "PUT",
        body: JSON.stringify({ projectId: "project", name: "Work", hasCustomName: false })
      })
      const session = (
        await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({
            id: "chat",
            projectId: "project",
            workspaceId: "work",
            harnessId: "codex",
            deferAgentSession: true
          })
        })
      ).body as { agentSessionId: string }
      const create = services.terminal.createTerminal
      vi.spyOn(services.terminal, "createTerminal").mockImplementation((request) =>
        Effect.gen(function* () {
          const terminal = yield* create(request)
          yield* services.db.updateWorkspace("work", { isArchived: true }).pipe(Effect.orDie)
          return terminal
        })
      )
      const result = await jsonRequest(server, "/v1/terminals", {
        method: "POST",
        body: JSON.stringify({ sessionId: "CHAT:pane", cwd: folder, cols: 80, rows: 24 })
      })
      expect(result.status).toBe(409)
      expect(spawner.processes[0]?.killCount).toBe(1)
      for (const key of ["chat", "chat:pane", `${session.agentSessionId}:bg:job`]) {
        expect(
          (
            await jsonRequest(server, "/v1/terminals", {
              method: "POST",
              body: JSON.stringify({ sessionId: key, cwd: folder, cols: 80, rows: 24 })
            })
          ).status
        ).toBe(409)
      }
    })
  }

  it("runs manual terminal cleanup when a PUT archives a workspace", async () => {
    const { server, services } = await setup()
    const payload = { projectId: "project", name: "Work", hasCustomName: false }
    await jsonRequest(server, "/v1/workspaces/work", {
      method: "PUT",
      body: JSON.stringify(payload)
    })
    await jsonRequest(server, "/v1/workspaces/work/panes/term", {
      method: "PUT",
      body: JSON.stringify({
        providerId: "codevisor",
        paneType: "terminal",
        resourceKind: "terminal",
        resourceId: "manual",
        title: "Terminal"
      })
    })
    const kill = vi.fn()
    services.terminal.registerExternalTerminal(
      { sessionId: "manual" },
      { kill, write: vi.fn(), resize: vi.fn() }
    )
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/work", {
          method: "PUT",
          body: JSON.stringify({ ...payload, isArchived: true })
        })
      ).status
    ).toBe(200)
    expect(kill).toHaveBeenCalledOnce()
  })
  it("publishes archive immediately and waits for a manual terminal without a chat", async () => {
    const { server, services, folder } = await setup()
    await jsonRequest(server, "/v1/workspaces/work", {
      method: "PUT",
      body: JSON.stringify({ projectId: "project", name: "Work", hasCustomName: false })
    })
    await jsonRequest(server, "/v1/workspaces/work/panes/term", {
      method: "PUT",
      body: JSON.stringify({
        providerId: "codevisor",
        paneType: "terminal",
        resourceKind: "terminal",
        resourceId: "manual",
        title: "Terminal"
      })
    })
    const started = Promise.withResolvers<void>()
    const cleanup = Promise.withResolvers<void>()
    const stop = vi.fn(async () => {
      started.resolve()
      await cleanup.promise
    })
    services.terminal.registerExternalTerminal(
      { sessionId: "manual" },
      { stop, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    const unrelated = vi.fn(async () => {})
    services.terminal.registerExternalTerminal(
      { sessionId: "another-worktree" },
      { stop: unrelated, kill: vi.fn(), write: vi.fn(), resize: vi.fn() }
    )
    let finished = false
    const archived = jsonRequest(server, "/v1/workspaces/work", {
      method: "PATCH",
      body: JSON.stringify({ isArchived: true })
    }).then((result) => {
      finished = true
      return result
    })
    try {
      await Promise.race([
        started.promise,
        archived.then((result) => {
          throw new Error(`Archive ended before cleanup started: ${JSON.stringify(result)}`)
        })
      ])
      expect(finished).toBe(false)
      expect(
        (await run(services.db.listEvents(0))).some(
          (event) =>
            event.kind === "workspace.updated" &&
            (event.payload as { isArchived?: boolean }).isArchived
        )
      ).toBe(true)
      expect(
        (
          await jsonRequest(server, "/v1/terminals", {
            method: "POST",
            body: JSON.stringify({ sessionId: "manual", cwd: folder, cols: 80, rows: 24 })
          })
        ).status
      ).toBe(409)
    } finally {
      cleanup.resolve()
    }
    expect((await archived).status).toBe(200)
    expect(stop).toHaveBeenCalledOnce()
    expect(unrelated).not.toHaveBeenCalled()
  })

  it("stops every chat before snapshotting a shared worktree, including concurrent chat archives", async () => {
    const { server, services, folder } = await setup()
    execFileSync("git", ["init"], { cwd: folder, stdio: "ignore" })
    execFileSync(
      "git",
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.com",
        "commit",
        "--allow-empty",
        "-m",
        "init"
      ],
      { cwd: folder, stdio: "ignore" }
    )
    // Reprobe the folder now that it is a Git repository.
    await jsonRequest(server, "/v1/projects", {
      method: "POST",
      body: JSON.stringify({ id: "git-project", folderPath: folder })
    })
    const root = mkdtempSync(join(tmpdir(), "codevisor-cleanup-worktrees-"))
    tempDirs.push(root)
    vi.stubEnv("CODEVISOR_WORKTREES_ROOT", root)
    const worktree = (
      await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        method: "POST",
        body: JSON.stringify({ name: "cleanup" })
      })
    ).body as { name: string; path: string }
    writeFileSync(join(worktree.path, "changes.txt"), "preserve this edit")
    await jsonRequest(server, "/v1/workspaces/work", {
      method: "PUT",
      body: JSON.stringify({
        projectId: "git-project",
        rootDirectory: worktree.path,
        name: "Work",
        hasCustomName: false
      })
    })
    const chats: Array<{ id: string; agentSessionId: string }> = []
    for (const id of ["one", "two"]) {
      chats.push(
        (
          await jsonRequest(server, "/v1/sessions", {
            method: "POST",
            body: JSON.stringify({
              id,
              projectId: "git-project",
              workspaceId: "work",
              worktreeName: worktree.name,
              harnessId: "codex"
            })
          })
        ).body as { id: string; agentSessionId: string }
      )
    }
    for (const chat of chats)
      await jsonRequest(server, `/v1/sessions/${chat.id}`, {
        method: "PATCH",
        body: JSON.stringify({ isArchived: true })
      })
    expect(existsSync(worktree.path)).toBe(true)
    const started = Promise.withResolvers<void>()
    const cleanup = Promise.withResolvers<void>()
    vi.spyOn(services.agents, "closeAgentSession").mockImplementation((id) =>
      Effect.promise(async () => {
        if (id === chats[1]!.agentSessionId) {
          started.resolve()
          await cleanup.promise
        }
      })
    )
    const archive = jsonRequest(server, "/v1/workspaces/work", {
      method: "PATCH",
      body: JSON.stringify({ isArchived: true })
    })
    let duplicate: ReturnType<typeof jsonRequest> | undefined
    try {
      await Promise.race([
        started.promise,
        archive.then((result) => {
          throw new Error(`Archive ended before cleanup started: ${JSON.stringify(result)}`)
        })
      ])
      // A second archive of the same workspace lands while the first is still
      // tearing down: the retry must be a no-op, not a second snapshot.
      duplicate = jsonRequest(server, "/v1/workspaces/work", {
        method: "PATCH",
        body: JSON.stringify({ isArchived: true })
      })
      expect(existsSync(join(worktree.path, "changes.txt"))).toBe(true)
      expect(
        (await run(services.db.listWorkspaces)).every((workspace) => workspace.isArchived)
      ).toBe(true)
      expect(
        (
          await jsonRequest(server, "/v1/sessions/two/prompt", {
            method: "POST",
            body: JSON.stringify({ text: "start again" })
          })
        ).status
      ).toBe(409)
    } finally {
      cleanup.resolve()
    }
    expect((await archive).status).toBe(200)
    expect((await duplicate)?.status).toBe(200)
    expect(existsSync(worktree.path)).toBe(false)
  })
})
