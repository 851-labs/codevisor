import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { buildV4Fixture, run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("upgrades a v30 database to durable attention state and backfills the active mode", async () => {
    const filename = tempDatabase()
    const current = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(current.createProject({ folderPath: "/tmp/v30-attention" }))
    const session = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(current.appendEvent("session.updated", session.id, { modeId: "plan" }))
    await Effect.runPromise(current.close)

    // Recreate the exact v30 boundary: all prior migrations and persisted
    // session events exist, while the attention tables and markers do not.
    // Reopening runs 31 (ledger tables + mode backfill), 37 (receipt
    // targets), and 42 (revision counter, which drops the ledger again)
    // atomically.
    const legacy = new Database(filename)
    legacy.pragma("foreign_keys = OFF")
    legacy.exec(`
      drop table session_read_state;
      drop table session_attention;
      delete from schema_migrations where id in (31, 37, 42);
    `)
    legacy.close()

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(upgraded.getSessionSummary(session.id))).toMatchObject({
      actionRequired: false,
      latestAttentionSequence: 0,
      lastSeenAttentionSequence: 0,
      unreadCount: 0
    })

    // The mode backfill is behaviorally important: a plan completed after the
    // upgrade must become a durable approval action even though the mode event
    // itself was written by v30. (It flows v31's backfill → v42's copy.)
    await run(
      upgraded.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-after-upgrade",
        turnState: "started"
      })
    )
    await run(
      upgraded.appendEvent("session.output", session.id, {
        markdown: "# Plan\n\nUpgrade safely.",
        sessionUpdate: "plan_document"
      })
    )
    await run(
      upgraded.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-after-upgrade",
        turnState: "ended"
      })
    )
    expect(await run(upgraded.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "planApproval",
      latestAttentionSequence: 0,
      pendingPlanApproval: true,
      unreadCount: 0
    })
    expect(await run(upgraded.migrate)).toEqual([])
    await Effect.runPromise(upgraded.close)

    const verified = new Database(filename)
    expect(verified.prepare("select name from schema_migrations where id = 31").get()).toEqual({
      name: "durable cross-device session attention"
    })
    expect(verified.pragma("foreign_key_check")).toEqual([])
    verified.close()
  })

  it("upgrades a v41 attention ledger to the revision counter", async () => {
    const filename = tempDatabase()
    const current = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(current.createProject({ folderPath: "/tmp/v41-attention" }))
    const read = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    const stuck = await run(
      current.createSession({ projectId: project.id, harnessId: "claude-code" })
    )
    const planning = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    await Effect.runPromise(current.close)

    // Recreate the v41 boundary with the old ledger populated: an unread
    // error past the shared cursor, a stuck pending epoch (the dev-server
    // hold bug this migration exists to unstick), and a pending approval.
    const legacy = new Database(filename)
    legacy.pragma("foreign_keys = OFF")
    legacy.exec(`
      drop table session_attention;
      delete from schema_migrations where id = 42;
      create table session_attention_state (
        session_id text primary key references sessions(id) on delete cascade,
        pending_epoch integer not null default 0,
        pending_error integer not null default 0,
        turn_active integer not null default 0,
        runtime_state text not null default 'idle',
        has_runtime_state integer not null default 0,
        current_mode_id text,
        pending_plan_approval integer not null default 0
      );
      create table session_attention_events (
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        source_revision integer not null,
        kind text not null,
        has_error integer not null default 0,
        created_at text not null,
        chat_item_id text,
        primary key(session_id, sequence)
      );
      insert into session_attention_events
        (session_id, sequence, source_revision, kind, has_error, created_at) values
        ('${read.id}', 1, 1, 'finished', 0, '2026-08-01T00:00:00.000Z'),
        ('${read.id}', 2, 2, 'finished', 0, '2026-08-01T00:01:00.000Z'),
        ('${read.id}', 3, 3, 'finished', 1, '2026-08-01T00:02:00.000Z');
      insert into session_read_state
        (session_id, reader_id, last_seen_sequence, manually_unread, updated_at) values
        ('${read.id}', 'owner', 2, 0, '2026-08-01T00:01:30.000Z');
      insert into session_attention_state (session_id, pending_epoch) values ('${stuck.id}', 1);
      insert into session_attention_state (session_id, current_mode_id, pending_plan_approval)
        values ('${planning.id}', 'plan', 1);
    `)
    legacy.close()

    const upgraded = await run(
      makeDatabase({ filename, serverId: "local", attentionSettleGraceMs: 0 })
    )
    // The revision inherits the ledger's sequence space, so the shared read
    // cursor carries over exactly: 3 settled turns, 2 seen, 1 unread error.
    expect(await run(upgraded.getSessionSummary(read.id))).toMatchObject({
      latestAttentionSequence: 3,
      lastSeenAttentionSequence: 2,
      unreadCount: 1,
      hasUnreadError: true,
      sidebarState: "errored"
    })
    // The stuck epoch became a parked finish for recovery to drain.
    expect((await run(upgraded.getSessionSummary(stuck.id))).sidebarState).toBe("inProgress")
    expect(await run(upgraded.listPendingAttentionSettles)).toEqual([
      { sessionId: stuck.id, dueAt: null }
    ])
    expect((await run(upgraded.settleSessionAttention(stuck.id))).settled).toBe(true)
    expect(await run(upgraded.getSessionSummary(stuck.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    // Intrinsic approval state carried over.
    expect(await run(upgraded.getSessionSummary(planning.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "planApproval",
      pendingPlanApproval: true,
      sidebarState: "waitingForUser"
    })
    await Effect.runPromise(upgraded.close)

    const verified = new Database(filename)
    expect(
      verified
        .prepare(
          `select name from sqlite_master where type = 'table'
           and name in ('session_attention_events', 'session_attention_state')`
        )
        .all()
    ).toEqual([])
    expect(verified.pragma("foreign_key_check")).toEqual([])
    verified.close()
  })

  it("upgrades a v44 database and backfills the newest valid session checklist", async () => {
    const filename = tempDatabase()
    const current = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(current.createProject({ folderPath: "/tmp/v44-checklists" }))
    const active = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    const completed = await run(
      current.createSession({ projectId: project.id, harnessId: "claude-code" })
    )
    const activePlan = {
      entries: [{ content: "Implement", priority: "medium", status: "in_progress" }]
    }
    const completedPlan = {
      entries: [{ content: "Verify", priority: "high", status: "completed" }]
    }
    await run(
      current.appendEvent("session.output", active.id, {
        sessionUpdate: "plan",
        entries: [{ content: "Inspect", priority: "low", status: "completed" }]
      })
    )
    await run(
      current.appendEvent("session.output", active.id, {
        sessionUpdate: "plan",
        ...activePlan
      })
    )
    // The migration must walk past an invalid newest event and recover the
    // last valid full snapshot rather than dropping this existing checklist.
    await run(
      current.appendEvent("session.output", active.id, {
        sessionUpdate: "plan",
        entries: [{ content: "Invalid", priority: "urgent", status: "pending" }]
      })
    )
    await run(
      current.appendEvent("session.output", completed.id, {
        sessionUpdate: "plan",
        ...completedPlan
      })
    )
    await Effect.runPromise(current.close)

    const legacy = new Database(filename)
    legacy.exec(`
      alter table sessions drop column session_plan;
      delete from schema_migrations where id = 45;
    `)
    legacy.close()

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    expect((await run(upgraded.getTranscriptPage(active.id, undefined, 8))).sessionPlan).toEqual(
      activePlan
    )
    expect((await run(upgraded.getTranscriptPage(completed.id, undefined, 8))).sessionPlan).toEqual(
      completedPlan
    )
    expect(await run(upgraded.migrate)).toEqual([])
    await Effect.runPromise(upgraded.close)

    const verified = new Database(filename)
    expect(verified.prepare("select name from schema_migrations where id = 45").get()).toEqual({
      name: "durable session checklists"
    })
    verified.close()
  })

  it("backfills archived timestamps for rows archived before the column existed", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    // Mark the pre-existing rows archived the way the old schema could: a bare
    // boolean with no moment attached.
    const legacy = new Database(filename)
    legacy.exec(`
      update sessions set is_archived = 1 where id = 'sess-1';
      update workspaces set is_archived = 1 where id = 'ws-1';
    `)
    legacy.close()

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))

    const session = await run(db.getSessionSummary("sess-1"))
    expect(session.isArchived).toBe(true)
    // A timestamp must exist so the row can be sorted and labelled in the
    // archived section rather than sinking to the bottom forever...
    expect(session.archivedAt).toBeDefined()
    // ...but it must not claim the chat was archived at migration time.
    expect(session.archivedAt?.startsWith("2026-06-01")).toBe(true)

    const project = (await run(db.listProjects)).find((candidate) => candidate.id === "ws-1")
    expect(project?.isArchived).toBe(true)
    expect(project?.archivedAt).toBeDefined()

    await run(db.close)
  })

  it("migrates a v4 database to projects without losing session children", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))

    const projects = await run(db.listProjects)
    expect(projects).toHaveLength(1)
    expect(projects[0]).toMatchObject({ id: "ws-1", name: "Codevisor", origin: "codevisor" })
    expect(projects[0]?.locations).toEqual([
      {
        id: "ws-1",
        projectId: "ws-1",
        serverId: "machine-a",
        folderPath: "/tmp/codevisor",
        createdAt: "2026-06-01T00:00:00.000Z"
      }
    ])

    const detail = await run(db.getSessionDetail("sess-1"))
    expect(detail.session).toMatchObject({
      projectId: "ws-1",
      harnessId: "codex",
      agentSessionId: "agent-1",
      cwd: "/tmp/codevisor"
    })
    expect(detail.session.worktreeName).toBeUndefined()
    expect(detail.conversation.map((item) => item.text)).toEqual(["hello"])
    expect((await run(db.getTranscriptPage("sess-1", undefined, 32))).items).toMatchObject([
      { role: "user", text: "hello" }
    ])
    expect(detail.promptQueue.map((item) => item.text)).toEqual(["queued"])
    expect(await run(db.getSessionActionResult("sess-1", "action-1"))).toEqual({})
    expect(await run(db.getSessionConfigSelections("sess-1"))).toEqual({})

    const sqlite = new Database(filename)
    expect(
      (
        sqlite.prepare("select title_is_user_set from sessions where id = 'sess-1'").get() as {
          title_is_user_set: number
        }
      ).title_is_user_set
    ).toBe(1)
    expect(
      JSON.parse(
        (
          sqlite.prepare("select payload from events where subject_id = 'sess-1'").get() as {
            payload: string
          }
        ).payload
      )
    ).toMatchObject({ origin: "codevisor" })
    expect(
      JSON.parse(
        (
          sqlite
            .prepare("select payload from session_events where session_id = 'sess-1'")
            .get() as { payload: string }
        ).payload
      )
    ).toMatchObject({ origin: "codevisor" })
    // Migration 5 dropped the legacy project-shaped `workspaces` table;
    // migration 21 reuses the freed name for empty pane workspaces, and adds
    // the sessions binding column.
    const workspaceColumns = (
      sqlite.pragma("table_info(workspaces)") as ReadonlyArray<{ readonly name: string }>
    ).map((column) => column.name)
    expect(workspaceColumns).toContain("project_id")
    expect(workspaceColumns).not.toContain("folder_path")
    expect(workspaceColumns).not.toContain("symbol_name")
    expect(
      (sqlite.pragma("table_info(projects)") as ReadonlyArray<{ readonly name: string }>).map(
        (column) => column.name
      )
    ).not.toContain("symbol_name")
    expect(sqlite.prepare("select count(*) as count from workspaces").get()).toEqual({ count: 0 })
    // Migration 22 added the workspace scratchpad table; migration 33 dropped
    // it again when the notes feature was removed. A fresh migrate run still
    // creates it on the way through, so only the end state matters here — the
    // table is gone and its already-logged events went with it.
    expect(
      sqlite
        .prepare("select name from sqlite_master where type = 'table' and name = 'workspace_notes'")
        .get()
    ).toBeUndefined()
    expect(
      sqlite
        .prepare("select count(*) as count from events where kind = 'workspace.notes.updated'")
        .get()
    ).toEqual({ count: 0 })
    expect(
      (sqlite.pragma("table_info(sessions)") as ReadonlyArray<{ readonly name: string }>).map(
        (column) => column.name
      )
    ).toEqual(expect.arrayContaining(["workspace_id", "config_selections"]))
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
         values ('orphan', 'missing-workspace', 'local', 'codex', 'Orphan', 'codevisor', 0, '2026-06-01T02:00:00.000Z')`
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

    const firstProject = await run(db.createProject({ folderPath: "/tmp/codevisor" }))
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
        origin: "imported",
        createdAt: "2026-06-30T00:00:00.000Z"
      })
    )
    expect(firstProject.name).toBe("codevisor")
    expect(secondProject.name).toBe("Named Project")
    expect(emptyProject.name).toBe("")
    expect(clientProject).toMatchObject({
      id: "project-client-id",
      name: "Client Project",
      isArchived: true,
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
        name: "Archived Codevisor"
      })
    )
    expect(updatedProject).toMatchObject({
      isArchived: true,
      name: "Archived Codevisor"
    })
    expect(await run(db.updateProject(secondProject.id, {}))).toMatchObject({
      isArchived: false,
      name: "Named Project"
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
    expect(firstSession.cwd).toBe("/tmp/codevisor")
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
    expect(
      await run(db.updateSessionTitleFromHarness(firstSession.id, "Harness replacement"))
    ).toBeUndefined()
    expect((await run(db.getSessionSummary(firstSession.id))).title).toBe("Renamed session")
    expect(
      await run(db.updateSessionTitleFromHarness(secondSession.id, "Harness title"))
    ).toMatchObject({ title: "Harness title" })

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
      (await run(db.reorderPromptQueue(firstSession.id, [queuedB.id, queuedA.id]))).map(
        (item) => item.text
      )
    ).toEqual(["queued b", "queued a"])
    expect(
      (await run(db.reorderPromptQueue(firstSession.id, ["missing", queuedA.id, queuedA.id]))).map(
        (item) => item.text
      )
    ).toEqual(["queued a", "queued b"])
    await run(db.reorderPromptQueue(firstSession.id, [queuedB.id, queuedA.id]))
    expect(
      await run(db.updatePromptQueueItem(firstSession.id, queuedB.id, "queued b edited"))
    ).toMatchObject({ text: "queued b edited" })
    expect(await run(db.claimPromptQueueItem(firstSession.id))).toMatchObject({
      id: queuedB.id,
      text: "queued b edited"
    })
    expect(await run(db.listPromptQueue(firstSession.id))).toMatchObject([{ id: queuedA.id }])
    expect(await run(db.listProcessingPromptQueue(firstSession.id))).toMatchObject([
      { id: queuedB.id }
    ])
    await run(db.completePromptQueueItem(firstSession.id, queuedB.id))
    await run(db.deletePromptQueueItem(firstSession.id, queuedA.id))
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
})
