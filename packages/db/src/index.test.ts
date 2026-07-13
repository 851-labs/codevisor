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
  it("persists harness accounts, selection, auth state, and session bindings", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ name: "Auth", folderPath: "/tmp/auth" }))

    const defaultAccount = await run(
      db.saveHarnessAccount({
        id: "default-codex",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    expect(defaultAccount.isActive).toBe(true)
    const updatedDefault = await run(
      db.saveHarnessAccount({
        id: "ignored-duplicate-id",
        harnessId: "codex",
        profileKind: "default",
        label: "Detected account",
        email: "person@example.com",
        organizationId: "org-1",
        authMethod: "chatgpt",
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        lastCheckedAt: "2026-07-10T00:00:00.000Z",
        detail: "Plus"
      })
    )
    expect(updatedDefault.id).toBe(defaultAccount.id)
    const expiredDefault = await run(
      db.updateHarnessAccountAuth(updatedDefault.id, { authState: "expired" })
    )
    expect(expiredDefault).toMatchObject({
      email: "person@example.com",
      organizationId: "org-1",
      authMethod: "chatgpt",
      detail: "Plus"
    })
    await expect(
      run(db.updateHarnessAccountAuth("missing-account", { authState: "error" }))
    ).rejects.toBeInstanceOf(DatabaseError)

    const managed = await run(
      db.saveHarnessAccount({
        id: "managed-codex",
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const sameManaged = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work renamed",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    expect(sameManaged.id).toBe(managed.id)
    expect((await run(db.listHarnessAccounts("codex"))).length).toBe(2)
    expect(await run(db.getHarnessAccount("missing"))).toBeUndefined()

    const authenticated = await run(
      db.updateHarnessAccountAuth(managed.id, {
        label: "Work account",
        email: "work@example.com",
        organizationId: null,
        authMethod: "device",
        authState: "authenticated",
        canLogin: false,
        canLogout: true,
        lastCheckedAt: "2026-07-10T01:00:00.000Z",
        detail: null
      })
    )
    expect(authenticated).toMatchObject({ email: "work@example.com", canLogout: true })
    const refreshed = await run(
      db.updateHarnessAccountAuth(managed.id, { authState: "authenticated" })
    )
    expect(refreshed.organizationId).toBeUndefined()
    expect(refreshed.detail).toBeUndefined()
    await run(db.setActiveHarnessAccount("codex", managed.id))
    expect((await run(db.getHarnessAccount(managed.id)))?.isActive).toBe(true)

    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", harnessAccountId: managed.id })
    )
    expect(session.harnessAccountId).toBe(managed.id)
    await expect(run(db.removeHarnessAccount(managed.id))).rejects.toBeInstanceOf(DatabaseError)
    await expect(run(db.removeHarnessAccount(defaultAccount.id))).rejects.toBeInstanceOf(
      DatabaseError
    )

    const removable = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        label: "Temporary",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const passive = await run(
      db.saveHarnessAccount({
        harnessId: "claude-code",
        profileKind: "managed",
        label: "Passive",
        authState: "notRequired",
        canLogin: false,
        canLogout: true
      })
    )
    expect(passive).toMatchObject({ canLogin: false, canLogout: true })
    await run(db.updateHarnessAccountAuth(passive.id, { authState: "notRequired" }))
    await run(db.updateHarnessAccountAuth(removable.id, { authState: "unauthenticated" }))
    await expect(
      run(db.setActiveHarnessAccount("claude-code", removable.id))
    ).rejects.toBeInstanceOf(DatabaseError)
    await run(db.removeHarnessAccount(removable.id))
    expect(await run(db.getHarnessAccount(removable.id))).toBeUndefined()

    const legacy = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(
      (await run(db.bindSessionHarnessAccount(legacy.id, defaultAccount.id))).harnessAccountId
    ).toBe(defaultAccount.id)
    await Effect.runPromise(db.close)
  })

  it("reports a reusable blocking data upgrade and installs the canonical schema", async () => {
    const filename = tempDatabase()
    const progress: Array<{
      state: string
      completed: number
      total: number
    }> = []
    const db = await run(
      makeDatabase({
        filename,
        serverId: "local",
        onDataUpgradeProgress: (update) => progress.push(update)
      })
    )

    expect(progress[0]?.state).toBe("running")
    expect(progress.at(-1)).toMatchObject({ state: "completed" })
    expect(progress.at(-1)?.completed).toBe(progress.at(-1)?.total)
    const sqlite = new Database(filename)
    for (const table of ["chat_items", "chat_parts", "session_events", "session_chat_state"]) {
      expect(
        sqlite
          .prepare("select name from sqlite_master where type = 'table' and name = ?")
          .get(table)
      ).toMatchObject({ name: table })
    }
    sqlite.close()
    await Effect.runPromise(db.close)
  })

  it("uses monotonic per-session revisions independent of the global event log", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/session-revisions" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const first = await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(db.appendEvent("project.updated", project.id, { title: "unrelated" }))
    const second = await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "hello"
      })
    )

    expect(first.subjectRevision).toBe(1)
    expect(first.globalEventId).toBeUndefined()
    expect(second.subjectRevision).toBe(2)
    expect(second.id).toBe(2)
    expect(second.globalEventId).toBeUndefined()
    expect((await run(db.listSubjectEvents(session.id))).map((event) => event.id)).toEqual([1, 2])
    expect((await run(db.listEvents(0))).map((event) => event.kind)).toEqual(["project.updated"])
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).eventCursor).toBe(2)
    await Effect.runPromise(db.close)
  })

  it("snapshots a pending question with the session cursor and clears it terminally", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/pending-question" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const question = {
      sessionUpdate: "question" as const,
      questionId: "question-1",
      questions: [
        {
          id: "choice",
          question: "Continue?",
          options: [{ label: "Yes" }, { label: "No" }],
          allowsOther: false
        }
      ]
    }

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(db.appendEvent("session.output", session.id, question))

    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      eventCursor: 2,
      pendingQuestion: question
    })
    expect((await run(db.getSessionDetail(session.id))).pendingQuestion).toEqual(question)

    const backgroundTasks = [
      {
        id: "task-1",
        description: "Run checks",
        status: "running",
        taskType: "shell"
      }
    ]
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks }))
    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      pendingQuestion: question,
      backgroundTasks
    })
    expect((await run(db.getSessionDetail(session.id))).backgroundTasks).toEqual(backgroundTasks)

    // A stale resolution must not release a newer pending continuation.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: "different-question",
        outcome: "cancelled",
        questions: []
      })
    )
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion).toEqual(
      question
    )

    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: question.questionId,
        outcome: "answered",
        questions: question.questions
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion
    ).toBeUndefined()
    // Resolution delivery is idempotent even after the blocking snapshot has
    // already been cleared.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: question.questionId,
        outcome: "answered",
        questions: question.questions
      })
    )
    await run(db.appendEvent("session.output", session.id, question))

    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).backgroundTasks).toEqual([])

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "ended",
        stopReason: "interrupted"
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion
    ).toBeUndefined()
    expect((await run(db.getSessionDetail(session.id))).pendingQuestion).toBeUndefined()
    await Effect.runPromise(db.close)
  })

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
    expect((await run(db.getTranscriptPage("sess-1", undefined, 32))).items).toMatchObject([
      { role: "user", text: "hello" }
    ])
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
    expect(
      await run(db.updateSession(secondSession.id, { worktreeName: "fix-auth" }))
    ).toMatchObject({
      worktreeName: "fix-auth"
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
    expect(event).toMatchObject({ subjectRevision: 1 })
    expect(event.globalEventId).toBeUndefined()
    expect(await run(db.listEvents(0))).toEqual([])
    expect((await run(db.getSessionDetail(firstSession.id))).eventCursor).toBe(1)
    await run(db.appendEvent("session.output", "other-subject", { text: "elsewhere" }))
    expect(await run(db.listEvents(0))).toMatchObject([
      { id: 1, kind: "session.output", payload: { text: "elsewhere" } }
    ])
    expect(await run(db.listSubjectEvents(firstSession.id))).toMatchObject([
      { id: 1, kind: "session.output", payload: { text: "chunk", index: 1 } }
    ])
    expect(await run(db.listSubjectEvents("unknown-subject"))).toEqual([])

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
    expect(await run(db.claimPromptQueueItem(firstSession.id))).toMatchObject({
      id: queuedA.id,
      text: "queued a"
    })
    expect(await run(db.listPromptQueue(firstSession.id))).toMatchObject([{ id: queuedB.id }])
    expect(await run(db.listProcessingPromptQueue(firstSession.id))).toMatchObject([
      { id: queuedA.id }
    ])
    await run(db.completePromptQueueItem(firstSession.id, queuedA.id))
    await run(db.deletePromptQueueItem(firstSession.id, queuedB.id))
    expect(await run(db.listPromptQueue(firstSession.id))).toEqual([])
    await expect(
      run(db.updatePromptQueueItem(firstSession.id, "missing-queue-item", "nope"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await expect(
      run(db.deletePromptQueueItem(firstSession.id, "missing-queue-item"))
    ).rejects.toBeInstanceOf(DatabaseError)
    expect(await run(db.claimPromptQueueItem(firstSession.id))).toBeUndefined()

    expect(await run(db.hasConversationMessage(firstSession.id, "dispatch-1"))).toBe(false)
    await run(db.appendConversationItem(firstSession.id, "user", "dispatch-1", "run it", false))
    expect(await run(db.hasConversationMessage(firstSession.id, "dispatch-1"))).toBe(true)
    expect(await run(db.hasTerminalAssistantAfterMessage(firstSession.id, "dispatch-1"))).toBe(
      false
    )
    await run(db.appendConversationItem(firstSession.id, "assistant", undefined, "done", false))
    expect(await run(db.hasTerminalAssistantAfterMessage(firstSession.id, "dispatch-1"))).toBe(true)

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

  it("coalesces streamed chunks of the same message into one conversation row", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/coalesce" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    // Token-sized chunks sharing a messageId extend the same row — one row
    // per message, not one per token (a 3000-word answer used to persist as
    // thousands of rows).
    await run(db.appendConversationItem(session.id, "user", "user-1", "tell me", false))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "Hel", true))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "lo ", true))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "world", false))
    // A new messageId starts a new row; a chunk without one never coalesces.
    await run(db.appendConversationItem(session.id, "assistant", "msg-2", "Next", false))
    await run(db.appendConversationItem(session.id, "assistant", undefined, "loose", false))
    await run(db.appendConversationItem(session.id, "assistant", undefined, "loose2", false))
    // Role changes break a run even with a matching id shape.
    await run(db.appendConversationItem(session.id, "user", "msg-2", "reply", false))

    const detail = await run(db.getSessionDetail(session.id))
    expect(
      detail.conversation.map((item) => [item.role, item.messageId, item.text, item.isGenerating])
    ).toEqual([
      ["user", "user-1", "tell me", false],
      ["assistant", "msg-1", "Hello world", false],
      ["assistant", "msg-2", "Next", false],
      ["assistant", undefined, "loose", false],
      ["assistant", undefined, "loose2", false],
      ["user", "msg-2", "reply", false]
    ])
  })

  it("projects bounded transcript pages and item-scoped details as events arrive", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/transcript-pages" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.appendEvent("session.output", session.id, { role: "user", text: "Explain it" }))
    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-1", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Hello " },
        messageId: "answer-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "world" },
        messageId: "answer-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: "tool-1",
        title: "Read a file"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-1",
        turnState: "ended",
        stopReason: "end_turn"
      })
    )

    const newest = await run(db.getTranscriptPage(session.id, undefined, 1))
    expect(newest).toMatchObject({ hasMore: true, nextBefore: "1", eventCursor: 6 })
    expect(newest.items).toHaveLength(1)
    expect(newest.items[0]).toMatchObject({
      sequence: 1,
      role: "assistant",
      text: "Hello world",
      isGenerating: false,
      hasDetails: true,
      turnId: "turn-1",
      stopReason: "end_turn"
    })

    const older = await run(db.getTranscriptPage(session.id, 1, 1))
    expect(older).toMatchObject({ hasMore: false, eventCursor: 6 })
    expect(older.nextBefore).toBeUndefined()
    expect(older.items).toMatchObject([{ sequence: 0, role: "user", text: "Explain it" }])

    const details = await run(db.getTranscriptItemDetails(session.id, newest.items[0]!.id))
    expect(details?.itemId).toBe(newest.items[0]!.id)
    expect(details?.events.map((event) => event.id)).toEqual([2, 3, 4, 5, 6])
    expect(await run(db.getTranscriptItemDetails(session.id, "missing"))).toBeUndefined()
  })

  it("backfills transcript pages from an older event log", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    const sqlite = new Database(filename)
    sqlite
      .prepare(
        "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
      )
      .run(
        "local",
        "session.output",
        "sess-1",
        "2026-06-01T01:04:00.000Z",
        JSON.stringify({ role: "user", text: "from history" })
      )
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const page = await run(db.getTranscriptPage("sess-1", undefined, 32))
    expect(page.items).toMatchObject([{ sequence: 0, role: "user", text: "from history" }])

    const migrated = new Database(filename)
    expect(
      migrated
        .prepare("select state, completed, total from backfill_jobs where id = ?")
        .get("canonical-session-chat-v1")
    ).toMatchObject({ state: "completed" })
    migrated.close()
  })

  it("only marks assistant turns with renderable worked details", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/worked-details" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "empty-work",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Answer without work" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "empty-work",
        turnState: "ended"
      })
    )

    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "visible-work",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Inspecting files" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Answer after work" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "visible-work",
        turnState: "ended"
      })
    )

    const page = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(page.items.filter((item) => item.role === "assistant")).toMatchObject([
      { text: "Answer without work", hasDetails: false },
      { text: "Answer after work", hasDetails: true }
    ])
  })

  it("repairs stale worked-detail markers when migration 10 is applied", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/worked-detail-migration" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    for (const turn of [
      { id: "empty", thought: "", answer: "No visible work" },
      { id: "visible", thought: "Inspecting files", answer: "Visible work" }
    ]) {
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: turn.id,
          turnState: "started"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          content: { type: "text", text: turn.thought },
          sessionUpdate: "agent_thought_chunk"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          content: { type: "text", text: turn.answer },
          sessionUpdate: "agent_message_chunk"
        })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: turn.id,
          turnState: "ended"
        })
      )
    }
    await run(db.close)

    const sqlite = new Database(filename)
    const items = sqlite
      .prepare("select id, has_details from chat_items where role = 'assistant' order by position")
      .all() as Array<{ id: string; has_details: number }>
    expect(items).toHaveLength(2)
    sqlite.prepare("update chat_items set has_details = 1 where id = ?").run(items[0]!.id)
    sqlite.prepare("update chat_items set has_details = 0 where id = ?").run(items[1]!.id)
    const insertSyntheticDetail = sqlite.prepare(
      `insert into session_events (
        session_id, revision, global_event_id, server_id, kind, created_at, payload, chat_item_id
      ) values (?, ?, null, 'local', 'session.output', ?, ?, ?)`
    )
    for (const [revision, payload] of [
      [9, "{"],
      [10, JSON.stringify({ sessionUpdate: 42 })],
      [11, JSON.stringify({ content: { type: "status" }, sessionUpdate: "agent_thought_chunk" })],
      [
        12,
        JSON.stringify({
          content: { type: "text", text: "Commentary" },
          phase: "commentary",
          sessionUpdate: "agent_message_chunk"
        })
      ],
      [
        13,
        JSON.stringify({
          content: { type: "text", text: "" },
          messageId: "retroactive-commentary",
          phase: "commentary",
          sessionUpdate: "agent_message_chunk"
        })
      ],
      [
        14,
        JSON.stringify({
          content: { type: "text", text: "" },
          phase: "commentary",
          sessionUpdate: "agent_message_chunk"
        })
      ]
    ] as const) {
      insertSyntheticDetail.run(
        session.id,
        revision,
        `2026-07-10T00:00:${String(revision).padStart(2, "0")}.000Z`,
        payload,
        items[1]!.id
      )
    }
    sqlite.prepare("delete from schema_migrations where id = 10").run()
    sqlite.close()

    const migrated = await run(makeDatabase({ filename, serverId: "local" }))
    const page = await run(migrated.getTranscriptPage(session.id, undefined, 32))
    expect(page.items.filter((item) => item.role === "assistant")).toMatchObject([
      { text: "No visible work", hasDetails: false },
      { text: "Visible work", hasDetails: true }
    ])
    await run(migrated.close)
  })

  it("projects alternate event shapes, plans, tools, and failed turns", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/event-shapes" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.appendEvent("session.output", session.id, "ignored non-object payload"))
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "chunked question" },
        messageId: "question-1"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "user_message_chunk",
        text: "without id"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "system",
        text: "system context",
        attachments: []
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-routed",
        turnState: "started"
      })
    )
    const streamingPage = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(streamingPage.items.at(-1)).toMatchObject({
      isGenerating: true,
      text: ""
    })
    expect(streamingPage.items.at(-1)?.planDocument).toBeUndefined()
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-routed",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "direct ",
        messageId: "answer-1"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "thinking" },
        messageId: "commentary-1",
        phase: "commentary"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "answer" },
        messageId: "answer-2",
        phase: "final"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        text: "anonymous answer"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "image" }
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "" },
        messageId: "empty"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "plan_document",
        markdown: "- [ ] ship"
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 32))).items.at(-1)?.planDocument
    ).toBe("- [ ] ship")
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: "tool-1",
        text: "tool detail"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call_update",
        parentToolCallId: "tool-1",
        toolCallId: "tool-child"
      })
    )
    await run(
      db.appendEvent("session.error", session.id, {
        message: "provider failed",
        stopReason: "error",
        turnId: "unknown-turn"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-empty",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        text: "commentary only",
        phase: "commentary"
      })
    )
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        stopReason: "manual",
        stopDetail: "manual detail"
      })
    )
    // A terminal event with no active item is a harmless no-op.
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    await run(
      db.appendEvent("session.created", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(
      db.appendEvent("session.archived", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(
      db.appendEvent("session.deleted", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(db.appendEvent("session.updated", project.id, null))
    await run(db.appendEvent("session.updated", project.id, { id: "metadata-without-project" }))
    await run(db.appendEvent("session.updated", session.id, { id: "metadata-without-project" }))
    await run(db.appendEvent("session.output", "missing-subject", { text: "orphan" }))

    const page = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(page.items.map((item) => item.role)).toEqual([
      "user",
      "user",
      "assistant",
      "assistant",
      "assistant"
    ])
    expect(page.items[0]?.text).toBe("chunked question")
    expect(page.items[1]?.text).toBe("without id")
    expect(page.items[2]).toMatchObject({
      hasDetails: true,
      isGenerating: false,
      planDocument: "- [ ] ship",
      text: "anonymous answer",
      stopDetail: "provider failed",
      stopReason: "error"
    })
    expect(page.items[3]?.text).toBe("")
    expect(page.items[3]?.stopReason).toBeUndefined()
    expect(page.items[4]).toMatchObject({ text: "", stopReason: "manual" })
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({ id: session.id })
    expect((await run(db.listSubjectEvents(session.id))).length).toBeGreaterThan(20)
    expect((await run(db.listSubjectEvents(project.id))).length).toBeGreaterThan(0)
    expect((await run(db.listSubjectEvents("missing-subject"))).length).toBe(1)
    await Effect.runPromise(db.close)
  })

  it("does not project ACP startup metadata as an assistant turn", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/acp-startup-metadata" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "opencode" }))

    await run(
      db.appendEvent("session.output", session.id, {
        availableCommands: [{ description: "Start a new session", name: "new" }],
        sessionUpdate: "available_commands_update"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        currentModeId: "build",
        sessionUpdate: "current_mode_update"
      })
    )

    expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toEqual([])

    await run(db.appendEvent("session.output", session.id, { role: "user", text: "hello" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "first-turn",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Hello! How can I help?" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "first-turn",
        turnState: "ended"
      })
    )

    expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toMatchObject([
      { role: "user", text: "hello" },
      { role: "assistant", text: "Hello! How can I help?" }
    ])
    await run(db.close)
  })

  it("backfills complete legacy transcript rows and blocks a mismatched projection", async () => {
    const filename = tempDatabase()
    const initial = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(initial.createProject({ folderPath: "/tmp/legacy-transcript" }))
    const session = await run(initial.createSession({ projectId: project.id, harnessId: "codex" }))
    const conversationFallback = await run(
      initial.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await Effect.runPromise(initial.close)

    const sqlite = new Database(filename)
    sqlite
      .prepare(
        `insert into transcript_items (
          id, session_id, sequence, role, text, created_at, updated_at,
          is_generating, has_details, turn_id, started_at, ended_at,
          stop_reason, stop_detail, plan_document, attachments, revision
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-assistant",
        session.id,
        0,
        "assistant",
        "legacy answer",
        "2026-06-01T00:00:00.000Z",
        "2026-06-01T00:01:00.000Z",
        0,
        1,
        "legacy-turn",
        "2026-06-01T00:00:00.000Z",
        "2026-06-01T00:01:00.000Z",
        "end_turn",
        "done",
        "legacy plan",
        '[{"fileId":"file-1","name":"a.txt","mimeType":"text/plain","sizeBytes":1,"kind":"document"}]',
        4
      )
    sqlite
      .prepare(
        `insert into transcript_items (
          id, session_id, sequence, role, text, created_at, updated_at,
          is_generating, has_details, turn_id, started_at, ended_at,
          stop_reason, stop_detail, plan_document, attachments, revision
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-user",
        session.id,
        1,
        "user",
        "legacy question",
        "2026-06-01T00:02:00.000Z",
        "2026-06-01T00:02:00.000Z",
        1,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        1
      )
    sqlite
      .prepare(
        `insert into conversation_items (
          id, session_id, role, text, created_at, is_generating, message_id, attachments
        ) values (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-conversation",
        conversationFallback.id,
        "user",
        "conversation fallback",
        "2026-06-01T00:03:00.000Z",
        1,
        "legacy-message",
        '[{"fileId":"file-2","name":"b.txt","mimeType":"text/plain","sizeBytes":2,"kind":"document"}]'
      )
    sqlite
      .prepare("insert into transcript_routes (session_id, route_key, item_id) values (?, ?, ?)")
      .run(session.id, "turn:legacy-turn", "legacy-assistant")
    sqlite
      .prepare(
        `insert into events (
          server_id, kind, subject_id, created_at, payload, transcript_item_id
        ) values (?, ?, ?, ?, ?, ?)`
      )
      .run(
        "local",
        "session.output",
        session.id,
        "2026-06-01T00:00:30.000Z",
        JSON.stringify({ role: "assistant", text: "legacy answer" }),
        "legacy-assistant"
      )
    sqlite
      .prepare("update backfill_jobs set state = 'failed', completed = 0 where id = ?")
      .run("canonical-session-chat-v1")
    sqlite.close()

    const migrated = await run(makeDatabase({ filename, serverId: "local" }))
    const page = await run(migrated.getTranscriptPage(session.id, undefined, 8))
    expect(page.items[0]).toMatchObject({
      id: "legacy-assistant",
      text: "legacy answer",
      planDocument: "legacy plan",
      attachments: [
        {
          fileId: "file-1",
          name: "a.txt",
          mimeType: "text/plain",
          sizeBytes: 1,
          kind: "document"
        }
      ],
      stopDetail: "done",
      stopReason: "end_turn",
      turnId: "legacy-turn"
    })
    expect(page.items[1]).toMatchObject({
      id: "legacy-user",
      isGenerating: true,
      text: "legacy question"
    })
    expect(
      (await run(migrated.getSessionDetail(conversationFallback.id))).conversation[0]
    ).toMatchObject({
      isGenerating: true,
      text: "conversation fallback"
    })
    const details = await run(migrated.getTranscriptItemDetails(session.id, "legacy-assistant"))
    expect(details?.events).toHaveLength(1)
    await Effect.runPromise(migrated.close)

    const corrupted = new Database(filename)
    corrupted
      .prepare("update chat_parts set text = 'corrupt' where item_id = ? and kind = 'text'")
      .run("legacy-assistant")
    corrupted
      .prepare("update backfill_jobs set state = 'failed' where id = ?")
      .run("canonical-session-chat-v1")
    corrupted.close()

    const progress: Array<{ state: string; error?: string | undefined }> = []
    await expect(
      run(
        makeDatabase({
          filename,
          serverId: "local",
          onDataUpgradeProgress: (update) => progress.push(update)
        })
      )
    ).rejects.toBeInstanceOf(DatabaseError)
    expect(progress.at(-1)).toMatchObject({ state: "failed" })
    expect(progress.at(-1)?.error).toContain("verification failed")
  })

  it("bounds transcript pages by text size as well as item count", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/transcript-page-budget" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    for (const marker of ["old", "middle", "new"]) {
      await run(
        db.appendEvent("session.output", session.id, {
          role: "user",
          text: `${marker}:${"x".repeat(15_000)}`
        })
      )
    }

    const newest = await run(db.getTranscriptPage(session.id, undefined, 8))
    expect(newest.items).toHaveLength(1)
    expect(newest.items[0]?.text.startsWith("new:")).toBe(true)
    expect(newest).toMatchObject({ hasMore: true, nextBefore: "2" })

    const older = await run(db.getTranscriptPage(session.id, 2, 16))
    expect(older.items).toHaveLength(2)
    expect(older.items[0]?.text.startsWith("old:")).toBe(true)
    expect(older.items[1]?.text.startsWith("middle:")).toBe(true)
    expect(older).toMatchObject({ hasMore: false })
  })

  it("coalescing handles attachments: empty array coalesces, non-empty stays its own row", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/coalesce-attach" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const meta = await run(db.createFile("a.png", "image/png", "image", Buffer.from([1, 2, 3])))
    const ref = {
      fileId: meta.id,
      name: meta.name,
      mimeType: meta.mimeType,
      sizeBytes: meta.sizeBytes,
      kind: meta.kind
    }

    // An explicit EMPTY attachments array still coalesces (length 0, row stays
    // attachment-free) — same as passing none.
    await run(db.appendConversationItem(session.id, "assistant", "m1", "He", true, []))
    await run(db.appendConversationItem(session.id, "assistant", "m1", "llo", false, []))
    // A chunk CARRYING attachments never coalesces onto/around: it inserts its
    // own row, and a following chunk can't extend it (its attachments != null).
    await run(db.appendConversationItem(session.id, "assistant", "m2", "pic", false, [ref]))
    await run(db.appendConversationItem(session.id, "assistant", "m2", "more", false, []))

    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => [item.role, item.messageId, item.text])).toEqual([
      ["assistant", "m1", "Hello"],
      ["assistant", "m2", "pic"],
      ["assistant", "m2", "more"]
    ])
    expect(detail.conversation[0]?.attachments).toBeUndefined()
    expect(detail.conversation[1]?.attachments).toEqual([ref])
    expect(detail.conversation[2]?.attachments).toBeUndefined()
  })

  it("stores file blobs and threads attachments through queue and conversation rows", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/attachments" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    const metadata = await run(db.createFile("shot.png", "image/png", "image", bytes))
    expect(metadata).toMatchObject({
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: bytes.byteLength,
      kind: "image"
    })
    expect(metadata.sha256).toHaveLength(64)

    const stored = await run(db.getFile(metadata.id))
    expect(stored?.metadata).toEqual(metadata)
    expect(stored?.data.equals(bytes)).toBe(true)
    expect(await run(db.getFileMetadata(metadata.id))).toEqual(metadata)
    expect(await run(db.getFile("missing-file"))).toBeUndefined()
    expect(await run(db.getFileMetadata("missing-file"))).toBeUndefined()

    const ref = {
      fileId: metadata.id,
      name: metadata.name,
      mimeType: metadata.mimeType,
      sizeBytes: metadata.sizeBytes,
      kind: metadata.kind
    }
    const queued = await run(db.createPromptQueueItem(session.id, "with file", [ref]))
    expect(queued.attachments).toEqual([ref])
    expect((await run(db.listPromptQueue(session.id)))[0]?.attachments).toEqual([ref])
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({
      text: "with file",
      attachments: [ref]
    })
    await run(db.completePromptQueueItem(session.id, queued.id))
    const queuedPlain = await run(db.createPromptQueueItem(session.id, "no file", []))
    expect(queuedPlain.attachments).toBeUndefined()
    expect(await run(db.claimPromptQueueItem(session.id))).toMatchObject({ text: "no file" })

    await run(
      db.appendConversationItem(session.id, "user", undefined, "look at this", false, [ref])
    )
    await run(db.appendConversationItem(session.id, "assistant", undefined, "nice", false))
    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation[0]?.attachments).toEqual([ref])
    expect(detail.conversation[1]?.attachments).toBeUndefined()

    // A literal empty JSON array in the canonical item reads back as "no attachments".
    const sqlite = new Database(filename)
    sqlite.prepare("update chat_items set attachments = '[]' where session_id = ?").run(session.id)
    sqlite.close()
    const emptied = await run(db.getSessionDetail(session.id))
    expect(emptied.conversation[0]?.attachments).toBeUndefined()

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

  it("persists MCP server configuration and encrypted credential payloads", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const created = await run(
      db.saveMcpServer({
        name: "Linear",
        transport: "http",
        url: "https://example.test/mcp",
        enabled: true,
        authType: "oauth",
        oauthScope: "read write",
        connectionState: "needsAuthorization",
        toolCount: 0,
        secretCipher: "opaque-ciphertext"
      })
    )
    expect(created).toMatchObject({
      authType: "oauth",
      enabled: true,
      name: "Linear",
      secretCipher: "opaque-ciphertext",
      transport: "http"
    })

    const updated = await run(
      db.saveMcpServer({
        id: created.id,
        name: created.name,
        transport: created.transport,
        ...(created.url === undefined ? {} : { url: created.url }),
        ...(created.command === undefined ? {} : { command: created.command }),
        args: created.args,
        enabled: created.enabled,
        authType: created.authType,
        ...(created.oauthScope === undefined ? {} : { oauthScope: created.oauthScope }),
        connectionState: "connected",
        toolCount: 18,
        ...(created.secretCipher === undefined ? {} : { secretCipher: created.secretCipher })
      })
    )
    expect(updated.connectionState).toBe("connected")
    expect((await run(db.listMcpServers))[0]?.toolCount).toBe(18)
    expect(await run(db.getMcpServer(created.id))).toMatchObject({
      id: created.id,
      name: "Linear",
      toolCount: 18
    })
    expect(await run(db.getMcpServer("missing-mcp"))).toBeUndefined()

    const local = await run(
      db.saveMcpServer({
        args: ["@playwright/mcp@latest"],
        authType: "none",
        command: "npx",
        connectionState: "error",
        detail: "Not installed",
        enabled: false,
        name: "Playwright",
        toolCount: 0,
        transport: "stdio"
      })
    )
    expect(local).toMatchObject({
      args: ["@playwright/mcp@latest"],
      command: "npx",
      detail: "Not installed",
      enabled: false
    })
    expect(local.url).toBeUndefined()
    expect(local.oauthScope).toBeUndefined()
    expect(local.secretCipher).toBeUndefined()
    expect((await run(db.resolveMcpServers())).map((server) => server.id)).toEqual([
      created.id,
      local.id
    ])

    const project = await run(db.createProject({ folderPath: "/tmp/mcp-scope" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    await run(db.setProjectMcpEnabled(project.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id)))[0]?.enabled).toBe(false)
    await run(db.setProjectMcpEnabled(project.id, created.id, true))
    await run(db.setSessionMcpEnabled(session.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(false)
    await run(db.setSessionMcpEnabled(session.id, created.id, true))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(true)

    await run(db.deleteMcpServer(created.id))
    await run(db.deleteMcpServer(local.id))
    expect(await run(db.listMcpServers)).toEqual([])
    await Effect.runPromise(db.close)
  })

  it("treats a folder as one project per server: idempotent creates and id merges", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const original = await run(db.createProject({ folderPath: "/tmp/duplicate" }))

    // Same folder, no explicit id → the existing project comes back.
    const again = await run(db.createProject({ folderPath: "/tmp/duplicate" }))
    expect(again.id).toBe(original.id)

    // Same id → idempotent.
    const byId = await run(db.createProject({ folderPath: "/tmp/other", id: original.id }))
    expect(byId.id).toBe(original.id)

    // Same folder under a NEW explicit id → the old project merges into it,
    // sessions and all — no unique-constraint failure.
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: original.id, title: "Kept" })
    )
    const merged = await run(
      db.createProject({
        folderPath: "/tmp/duplicate",
        id: "client-id-2",
        isArchived: true,
        name: "merged",
        origin: "imported",
        symbolName: "shippingbox"
      })
    )
    expect(merged.id).toBe("client-id-2")
    expect(merged.isArchived).toBe(true)
    expect(merged.name).toBe("merged")

    // Merge again with a bare request — defaults apply on the merge path too.
    const remerged = await run(
      db.createProject({ folderPath: "/tmp/duplicate", id: "client-id-3" })
    )
    expect(remerged.id).toBe("client-id-3")
    expect(remerged.isArchived).toBe(false)
    expect(remerged.name).toBe("duplicate")
    expect(merged.locations[0]?.folderPath).toBe("/tmp/duplicate")
    const projects = await run(db.listProjects)
    expect(projects.map((project) => project.id)).not.toContain(original.id)
    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.session.projectId).toBe("client-id-3")

    // Genuine sqlite failures still surface as tagged errors.
    const failed = await Effect.runPromiseExit(
      db.createSession({ harnessId: "codex", projectId: "missing-project", title: "x" })
    )
    expect(String(failed)).toContain("DatabaseError")
    await Effect.runPromise(db.close)
  })
})
