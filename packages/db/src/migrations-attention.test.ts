import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db attention and checklist upgrades", () => {
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
})
