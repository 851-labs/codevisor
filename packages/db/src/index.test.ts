import type { Harness } from "@herdman/api"
import Database from "better-sqlite3"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { DatabaseError, HerdManDatabase, makeDatabase, worktreePath } from "./index.js"

const tempDirs: Array<string> = []

const tempDatabase = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "herdman-db-"))
  tempDirs.push(dir)
  return join(dir, "herdman.sqlite")
}

const run = <A>(effect: Effect.Effect<A, DatabaseError>): Promise<A> => Effect.runPromise(effect)

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true })
  }
})

/** Recreates the on-disk shape of a database last touched by migration 4. */
const buildV4Fixture = (filename: string): void => {
  const sqlite = new Database(filename)
  sqlite.exec(`
    create table schema_migrations (id integer primary key, name text not null);
    insert into schema_migrations (id, name) values
      (1, 'initial'), (2, 'session action idempotency'),
      (3, 'conversation message ids'), (4, 'session prompt queue');

    create table workspaces (
      id text primary key,
      name text not null,
      folder_path text not null unique,
      is_archived integer not null default 0,
      symbol_name text not null default 'folder',
      origin text not null,
      created_at text not null
    );

    create table sessions (
      id text primary key,
      workspace_id text not null references workspaces(id) on delete cascade,
      server_id text not null,
      harness_id text not null,
      agent_session_id text,
      title text not null,
      origin text not null,
      is_archived integer not null default 0,
      created_at text not null,
      updated_at text,
      usage_used integer,
      usage_size integer,
      cost_amount real,
      cost_currency text
    );

    create table conversation_items (
      id text primary key,
      session_id text not null references sessions(id) on delete cascade,
      role text not null,
      text text not null,
      created_at text not null,
      is_generating integer not null default 0,
      message_id text
    );

    create table events (
      id integer primary key autoincrement,
      server_id text not null,
      kind text not null,
      subject_id text not null,
      created_at text not null,
      payload text not null
    );

    create table harness_settings (harness_id text primary key, enabled integer not null);

    create table auth_tokens (
      id text primary key,
      token_hash text not null unique,
      scope text not null,
      created_at text not null
    );

    create table update_state (
      id integer primary key check (id = 1),
      current_version text not null,
      latest_version text not null,
      update_available integer not null,
      channel text not null,
      checked_at text,
      migration_state text not null
    );

    create table backfill_jobs (
      id text primary key,
      name text not null,
      state text not null,
      cursor text,
      updated_at text not null
    );

    create table session_actions (
      session_id text not null references sessions(id) on delete cascade,
      client_action_id text not null,
      action_kind text not null,
      response text not null,
      created_at text not null,
      primary key (session_id, client_action_id)
    );

    create table prompt_queue_items (
      id text primary key,
      session_id text not null references sessions(id) on delete cascade,
      text text not null,
      created_at text not null,
      updated_at text not null
    );

    insert into workspaces (id, name, folder_path, is_archived, symbol_name, origin, created_at)
      values ('ws-1', 'HerdMan', '/tmp/herdman', 0, 'folder', 'herdman', '2026-06-01T00:00:00.000Z');
    insert into sessions (id, workspace_id, server_id, harness_id, agent_session_id, title, origin, is_archived, created_at)
      values ('sess-1', 'ws-1', 'local', 'codex', 'agent-1', 'Old Session', 'herdman', 0, '2026-06-01T01:00:00.000Z');
    insert into conversation_items (id, session_id, role, text, created_at, is_generating, message_id)
      values ('conv-1', 'sess-1', 'user', 'hello', '2026-06-01T01:01:00.000Z', 0, 'user-1');
    insert into prompt_queue_items (id, session_id, text, created_at, updated_at)
      values ('queue-1', 'sess-1', 'queued', '2026-06-01T01:02:00.000Z', '2026-06-01T01:02:00.000Z');
    insert into session_actions (session_id, client_action_id, action_kind, response, created_at)
      values ('sess-1', 'action-1', 'prompt', '{}', '2026-06-01T01:03:00.000Z');
  `)
  sqlite.close()
}

describe("@herdman/db", () => {
  it("migrates a v4 database to projects without losing session children", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))

    const projects = await run(db.listProjects)
    expect(projects).toHaveLength(1)
    expect(projects[0]).toMatchObject({ id: "ws-1", name: "HerdMan", origin: "herdman" })
    expect(projects[0]?.locations).toEqual([
      {
        id: "ws-1",
        projectId: "ws-1",
        serverId: "machine-a",
        folderPath: "/tmp/herdman",
        createdAt: "2026-06-01T00:00:00.000Z"
      }
    ])

    const detail = await run(db.getSessionDetail("sess-1"))
    expect(detail.session).toMatchObject({
      projectId: "ws-1",
      harnessId: "codex",
      agentSessionId: "agent-1",
      cwd: "/tmp/herdman"
    })
    expect(detail.session.worktreeName).toBeUndefined()
    expect(detail.conversation.map((item) => item.text)).toEqual(["hello"])
    expect(detail.promptQueue.map((item) => item.text)).toEqual(["queued"])
    expect(await run(db.getSessionActionResult("sess-1", "action-1"))).toEqual({})

    const sqlite = new Database(filename)
    expect(
      sqlite
        .prepare("select name from sqlite_master where type = 'table' and name = 'workspaces'")
        .get()
    ).toBeUndefined()
    expect(sqlite.pragma("foreign_key_check")).toEqual([])
    sqlite.close()

    expect(await run(db.migrate)).toEqual([])
    await Effect.runPromise(db.close)
  })

  it("refuses to migrate a database with orphaned child rows", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    // With enforcement off an orphan can sneak in; the migration's
    // foreign_key_check must catch it.
    const sqlite = new Database(filename)
    sqlite.pragma("foreign_keys = OFF")
    sqlite
      .prepare(
        `insert into sessions (id, workspace_id, server_id, harness_id, title, origin, is_archived, created_at)
         values ('orphan', 'missing-workspace', 'local', 'codex', 'Orphan', 'herdman', 0, '2026-06-01T02:00:00.000Z')`
      )
      .run()
    sqlite.close()

    await expect(run(makeDatabase({ filename, serverId: "local" }))).rejects.toBeInstanceOf(
      DatabaseError
    )
  })

  it("migrates once and persists projects, sessions, conversation, and events", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))

    expect(await run(db.migrate)).toEqual([])

    const firstProject = await run(db.createProject({ folderPath: "/tmp/herdman" }))
    const secondProject = await run(
      db.createProject({ folderPath: "/tmp/named", name: "Named Project" })
    )
    const emptyProject = await run(db.createProject({ folderPath: "" }))
    const clientProject = await run(
      db.createProject({
        id: "project-client-id",
        folderPath: "/tmp/client",
        name: "Client Project",
        isArchived: true,
        symbolName: "externaldrive",
        origin: "imported",
        createdAt: "2026-06-30T00:00:00.000Z"
      })
    )
    expect(firstProject.name).toBe("herdman")
    expect(secondProject.name).toBe("Named Project")
    expect(emptyProject.name).toBe("")
    expect(clientProject).toMatchObject({
      id: "project-client-id",
      name: "Client Project",
      isArchived: true,
      symbolName: "externaldrive",
      origin: "imported",
      createdAt: "2026-06-30T00:00:00.000Z"
    })
    expect(clientProject.locations).toHaveLength(1)
    expect(clientProject.locations[0]).toMatchObject({
      projectId: "project-client-id",
      serverId: "local",
      folderPath: "/tmp/client"
    })

    const updatedProject = await run(
      db.updateProject(firstProject.id, {
        isArchived: true,
        name: "Archived HerdMan",
        symbolName: "archivebox"
      })
    )
    expect(updatedProject).toMatchObject({
      isArchived: true,
      name: "Archived HerdMan",
      symbolName: "archivebox"
    })
    expect(await run(db.updateProject(secondProject.id, {}))).toMatchObject({
      isArchived: false,
      name: "Named Project",
      symbolName: "folder.fill"
    })
    await expect(run(db.updateProject("missing", { name: "nope" }))).rejects.toBeInstanceOf(
      DatabaseError
    )

    const firstSession = await run(
      db.createSession({
        projectId: firstProject.id,
        harnessId: "codex",
        agentSessionId: "agent-1"
      })
    )
    const secondSession = await run(
      db.createSession({
        projectId: secondProject.id,
        harnessId: "claude-code",
        title: "Explicit title"
      })
    )
    const clientSession = await run(
      db.createSession({
        id: "session-client-id",
        projectId: clientProject.id,
        harnessId: "codex",
        agentSessionId: "agent-client-id",
        title: "Client Session",
        origin: "imported",
        isArchived: true,
        createdAt: "2026-06-30T00:00:00.000Z",
        updatedAt: "2026-06-30T00:01:00.000Z"
      })
    )
    expect(firstSession.title).toBe("New Session")
    expect(firstSession.agentSessionId).toBe("agent-1")
    expect(firstSession.cwd).toBe("/tmp/herdman")
    expect(firstSession.worktreeName).toBeUndefined()
    expect(secondSession.title).toBe("Explicit title")
    expect(clientSession).toMatchObject({
      agentSessionId: "agent-client-id",
      id: "session-client-id",
      isArchived: true,
      origin: "imported",
      title: "Client Session",
      updatedAt: "2026-06-30T00:01:00.000Z"
    })
    expect(await run(db.updateSession(secondSession.id, {}))).toMatchObject({
      isArchived: false,
      title: "Explicit title"
    })
    expect(
      await run(db.updateSession(secondSession.id, { agentSessionId: "agent-2" }))
    ).toMatchObject({
      agentSessionId: "agent-2",
      title: "Explicit title"
    })

    const renamedSession = await run(
      db.updateSession(firstSession.id, { isArchived: true, title: "Renamed session" })
    )
    expect(renamedSession).toMatchObject({
      isArchived: true,
      title: "Renamed session"
    })

    await run(db.appendConversationItem(firstSession.id, "user", "user-1", "hello", false))
    await run(
      db.appendConversationItem(firstSession.id, "assistant", "assistant-1", "streaming", true)
    )
    await run(db.appendConversationItem(firstSession.id, "assistant", undefined, "no id", false))
    const detail = await run(db.getSessionDetail(firstSession.id))
    expect(detail.eventCursor).toBe(0)
    expect(
      detail.conversation.map((item) => [item.role, item.messageId, item.text, item.isGenerating])
    ).toEqual([
      ["user", "user-1", "hello", false],
      ["assistant", "assistant-1", "streaming", true],
      ["assistant", undefined, "no id", false]
    ])

    const event = await run(
      db.appendEvent("session.output", firstSession.id, { text: "chunk", index: 1 })
    )
    expect(event.id).toBe(1)
    expect(await run(db.listEvents(0))).toMatchObject([
      { id: 1, kind: "session.output", payload: { text: "chunk", index: 1 } }
    ])
    expect(await run(db.listEvents(1))).toEqual([])
    expect((await run(db.getSessionDetail(firstSession.id))).eventCursor).toBe(1)

    expect(await run(db.getSessionActionResult(firstSession.id, "prompt-1"))).toBeUndefined()
    await run(
      db.saveSessionActionResult(firstSession.id, "prompt-1", "prompt", {
        stopReason: "end_turn"
      })
    )
    await run(
      db.saveSessionActionResult(firstSession.id, "prompt-1", "prompt", {
        stopReason: "duplicate_should_not_replace"
      })
    )
    expect(await run(db.getSessionActionResult(firstSession.id, "prompt-1"))).toEqual({
      stopReason: "end_turn"
    })

    const queuedA = await run(db.createPromptQueueItem(firstSession.id, "queued a"))
    const queuedB = await run(db.createPromptQueueItem(firstSession.id, "queued b"))
    expect(
      (await run(db.getSessionDetail(firstSession.id))).promptQueue.map((item) => item.text)
    ).toEqual(["queued a", "queued b"])
    expect(
      await run(db.updatePromptQueueItem(firstSession.id, queuedB.id, "queued b edited"))
    ).toMatchObject({ text: "queued b edited" })
    expect(await run(db.shiftPromptQueueItem(firstSession.id))).toMatchObject({
      id: queuedA.id,
      text: "queued a"
    })
    await run(db.deletePromptQueueItem(firstSession.id, queuedB.id))
    expect(await run(db.listPromptQueue(firstSession.id))).toEqual([])
    await expect(
      run(db.updatePromptQueueItem(firstSession.id, "missing-queue-item", "nope"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await expect(
      run(db.deletePromptQueueItem(firstSession.id, "missing-queue-item"))
    ).rejects.toBeInstanceOf(DatabaseError)
    expect(await run(db.shiftPromptQueueItem(firstSession.id))).toBeUndefined()

    const sqlite = new Database(filename)
    sqlite
      .prepare(
        "update sessions set usage_used = 12, usage_size = 120, cost_amount = 0.42, cost_currency = 'USD' where id = ?"
      )
      .run(firstSession.id)
    sqlite.close()
    expect((await run(db.getSessionDetail(firstSession.id))).session.usage).toEqual({
      costAmount: 0.42,
      costCurrency: "USD",
      size: 120,
      used: 12
    })

    expect((await run(db.listSessions)).map((session) => session.id)).toContain(firstSession.id)
    expect((await run(db.listProjects)).map((project) => project.id)).toContain(secondProject.id)

    expect((await run(db.archiveSession(firstSession.id))).isArchived).toBe(true)
    await expect(run(db.updateSession("missing", { title: "Missing" }))).rejects.toBeInstanceOf(
      DatabaseError
    )
    await expect(run(db.archiveSession("missing"))).rejects.toBeInstanceOf(DatabaseError)
    await run(db.deleteSession(secondSession.id))
    await expect(run(db.getSessionDetail(secondSession.id))).rejects.toBeInstanceOf(DatabaseError)
    await run(db.deleteProject(clientProject.id))
    await expect(run(db.getSessionDetail(clientSession.id))).rejects.toBeInstanceOf(DatabaseError)
    await expect(run(db.deleteProject("missing"))).rejects.toBeInstanceOf(DatabaseError)

    await Effect.runPromise(db.close)
  })

  it("tracks worktrees and derives worktree session cwds", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/worktree-project" }))

    const worktree = await run(db.createWorktree(project.id, "fix-auth", "herdman/fix-auth"))
    expect(worktree).toMatchObject({
      projectId: project.id,
      serverId: "local",
      name: "fix-auth",
      branch: "herdman/fix-auth",
      path: join(homedir(), "herdman", project.id, "fix-auth")
    })
    expect(worktree.path).toBe(worktreePath(project.id, "fix-auth"))

    expect(await run(db.listWorktrees(project.id))).toEqual([worktree])
    expect(await run(db.listWorktrees("missing"))).toEqual([])

    // Same name for the same project on the same server is rejected.
    await expect(
      run(db.createWorktree(project.id, "fix-auth", "herdman/fix-auth-2"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await expect(
      run(db.createWorktree("missing", "fix-auth", "herdman/fix-auth"))
    ).rejects.toBeInstanceOf(DatabaseError)

    const session = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        worktreeName: "fix-auth"
      })
    )
    expect(session.worktreeName).toBe("fix-auth")
    expect(session.cwd).toBe(worktreePath(project.id, "fix-auth"))

    const doomed = await run(db.createWorktree(project.id, "doomed", "herdman/doomed"))
    await run(db.deleteWorktree(doomed.id))
    expect((await run(db.listWorktrees(project.id))).map((w) => w.name)).toEqual(["fix-auth"])
    // Deleting an unknown worktree is a no-op rather than an error.
    await run(db.deleteWorktree("missing"))

    // Worktree rows are removed with their project.
    await run(db.deleteProject(project.id))
    expect(await run(db.listWorktrees(project.id))).toEqual([])

    await Effect.runPromise(db.close)
  })

  it("omits session cwd when the project has no folder on this server", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/elsewhere" }))
    await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await Effect.runPromise(db.close)

    // A server without a location for the project cannot derive a cwd.
    const other = await run(makeDatabase({ filename, serverId: "machine-b" }))
    const sessions = await run(other.listSessions)
    expect(sessions[0]?.cwd).toBeUndefined()
    await Effect.runPromise(other.close)
  })

  it("applies harness settings, auth tokens, and update state", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "server-a" }))
    const harnesses: ReadonlyArray<Harness> = [
      {
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "npx",
        enabled: true,
        readiness: { state: "ready" }
      },
      {
        id: "claude-code",
        name: "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: { state: "unavailable", detail: "missing" }
      }
    ]

    expect(await run(db.applyHarnessSettings(harnesses))).toEqual(harnesses)
    await run(db.setHarnessEnabled("codex", false))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([false, true])
    await run(db.setHarnessEnabled("codex", true))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([true, true])

    const token = await run(db.issuePairingToken)
    expect(token.startsWith("hm_")).toBe(true)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    expect(await run(db.verifyBearerToken("hm_wrong"))).toBe(false)

    expect(await run(db.getUpdateInfo)).toMatchObject({
      currentVersion: "0.1.0",
      updateAvailable: false,
      migrationState: "idle"
    })
    const update = await run(
      db.setUpdateInfo({
        currentVersion: "0.1.0",
        latestVersion: "0.2.0",
        updateAvailable: true,
        channel: "development",
        checkedAt: "2026-06-30T01:00:00.000Z",
        migrationState: "running"
      })
    )
    expect(update.updateAvailable).toBe(true)
    expect(await run(db.getUpdateInfo)).toEqual(update)
    expect(
      await run(
        db.setUpdateInfo({
          currentVersion: "0.2.0",
          latestVersion: "0.2.0",
          updateAvailable: false,
          channel: "stable",
          migrationState: "idle"
        })
      )
    ).toEqual({
      currentVersion: "0.2.0",
      latestVersion: "0.2.0",
      updateAvailable: false,
      channel: "stable",
      migrationState: "idle"
    })

    await Effect.runPromise(db.close)
  })

  it("constructs the Effect service layer", async () => {
    const info = await Effect.runPromise(
      Effect.gen(function* () {
        const db = yield* HerdManDatabase
        const update = yield* db.getUpdateInfo
        yield* db.close
        return update
      }).pipe(
        Effect.provide(
          HerdManDatabase.layer({
            filename: tempDatabase(),
            serverId: "layered"
          })
        )
      )
    )

    expect(info.currentVersion).toBe("0.1.0")
  })

  it("surfaces sqlite errors as tagged database errors", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    await run(db.createProject({ folderPath: "/tmp/duplicate" }))
    const failed = await Effect.runPromiseExit(db.createProject({ folderPath: "/tmp/duplicate" }))
    expect(String(failed)).toContain("DatabaseError")
    await Effect.runPromise(db.close)
  })
})
