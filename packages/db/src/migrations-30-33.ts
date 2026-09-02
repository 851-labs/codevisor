import { randomUUID } from "node:crypto"
import type { Migration } from "./migration-types.js"

/// Schema migrations 30–33.
export const migrations30To33: ReadonlyArray<Migration> = [
  {
    id: 30,
    name: "canonical lowercase uuid ids",
    // UUID ids are compared byte-wise in TEXT columns, but clients disagree on
    // rendering (Swift uppercases, Node lowercases). Sessions never got the
    // lowercase canonicalization projects received, so opening a remotely
    // created (lowercase) session from the macOS app (uppercase paths) missed
    // the existing row and create-if-missing minted a case-twin duplicate —
    // the "duplicate agents/workspaces in the sidebar" bug. This migration
    // makes lowercase canonical everywhere and repairs the damage:
    //  1. Case-twin session groups are merged: twins without any transcript
    //     are phantom forks and are deleted outright; twins that were
    //     genuinely prompted are kept under a fresh lowercase id and archived
    //     so no data is lost but the duplicate leaves the sidebar.
    //  2. Session ids (and their child-table references) are lowercased.
    //  3. Project/worktree/workspace ids and uuid-shaped event subjects are
    //     lowercased where no differently-cased twin row blocks the rename.
    sql: "",
    run: (sqlite) => {
      const sessionChildTables = [
        "conversation_items",
        "session_actions",
        "prompt_queue_items",
        "transcript_items",
        "transcript_projection_state",
        "transcript_routes",
        "chat_items",
        "session_chat_state",
        "chat_item_routes",
        "session_events",
        "session_mcp_settings"
      ]
      const rekeySessionChildren = (from: string, to: string): void => {
        for (const table of sessionChildTables) {
          sqlite.prepare(`update ${table} set session_id = ? where session_id = ?`).run(to, from)
        }
        sqlite.prepare("update events set subject_id = ? where subject_id = ?").run(to, from)
      }
      const hasTranscript = (sessionId: string): boolean =>
        ["chat_items", "transcript_items", "conversation_items"].some(
          (table) =>
            sqlite.prepare(`select 1 from ${table} where session_id = ? limit 1`).get(sessionId) !==
            undefined
        )

      // 1. Merge case-twin sessions. The canonical survivor is the most
      // recently active twin that actually has a transcript (falling back to
      // plain recency when none do).
      const twinGroups = sqlite
        .prepare("select lower(id) as lid from sessions group by lower(id) having count(*) > 1")
        .all() as ReadonlyArray<{ readonly lid: string }>
      for (const group of twinGroups) {
        const rows = sqlite
          .prepare(
            `select id from sessions where lower(id) = ?
             order by coalesce(updated_at, created_at) desc`
          )
          .all(group.lid) as ReadonlyArray<{ readonly id: string }>
        const canonical = (rows.find((row) => hasTranscript(row.id)) ?? rows[0]!).id
        for (const row of rows) {
          if (row.id === canonical) {
            continue
          }
          if (!hasTranscript(row.id)) {
            // A phantom fork: created by a case-missed lookup and never
            // prompted. Dropping it (and its bookkeeping rows) is lossless.
            for (const table of sessionChildTables) {
              sqlite.prepare(`delete from ${table} where session_id = ?`).run(row.id)
            }
            sqlite.prepare("delete from sessions where id = ?").run(row.id)
            continue
          }
          // Both twins were prompted, so their transcripts genuinely forked.
          // Keep the loser's data under a fresh id, archived, instead of
          // guessing how to interleave two histories.
          const fresh = randomUUID()
          rekeySessionChildren(row.id, fresh)
          sqlite
            .prepare("update sessions set id = ?, is_archived = 1 where id = ?")
            .run(fresh, row.id)
        }
      }

      // 2. Lowercase session ids and every child reference. Safe after the
      // merge above: no two remaining sessions share a lowercase id.
      for (const table of sessionChildTables) {
        sqlite.exec(
          `update ${table} set session_id = lower(session_id) where session_id != lower(session_id)`
        )
      }
      sqlite.exec("update sessions set id = lower(id) where id != lower(id)")

      // 3. Projects, worktrees, and workspaces: lowercase ids where no
      // differently-cased twin already claims the lowercase spelling (twins
      // are still served correctly by the nocase project lookups), then align
      // the columns referencing them.
      sqlite.exec(`
        update projects set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from projects twin where twin.id = lower(projects.id));
        update worktrees set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from worktrees twin where twin.id = lower(worktrees.id));
        update workspaces set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from workspaces twin where twin.id = lower(workspaces.id));
        update project_locations set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(project_locations.project_id));
        update worktrees set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(worktrees.project_id));
        update workspaces set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(workspaces.project_id));
        update sessions set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(sessions.project_id));
        update sessions set workspace_id = lower(workspace_id)
          where workspace_id is not null and workspace_id != lower(workspace_id)
            and exists (select 1 from workspaces where workspaces.id = lower(sessions.workspace_id));
        update project_mcp_settings set project_id = lower(project_id)
          where project_id != lower(project_id)
            and not exists (
              select 1 from project_mcp_settings twin
              where twin.project_id = lower(project_mcp_settings.project_id)
                and twin.mcp_server_id = project_mcp_settings.mcp_server_id
            );
        update events set subject_id = lower(subject_id)
          where subject_id != lower(subject_id)
            and subject_id like '________-____-____-____-____________';
      `)
    }
  },
  {
    id: 31,
    name: "durable cross-device session attention",
    sql: `
      create table if not exists session_attention_state (
        session_id text primary key references sessions(id) on delete cascade,
        pending_epoch integer not null default 0 check(pending_epoch in (0, 1)),
        pending_error integer not null default 0 check(pending_error in (0, 1)),
        turn_active integer not null default 0 check(turn_active in (0, 1)),
        runtime_state text not null default 'idle'
          check(runtime_state in ('running', 'idle', 'requires_action')),
        has_runtime_state integer not null default 0 check(has_runtime_state in (0, 1)),
        current_mode_id text,
        pending_plan_approval integer not null default 0
          check(pending_plan_approval in (0, 1))
      );

      create table if not exists session_attention_events (
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        source_revision integer not null,
        kind text not null check(kind in ('finished', 'action_required')),
        has_error integer not null default 0 check(has_error in (0, 1)),
        created_at text not null,
        primary key(session_id, sequence),
        unique(session_id, source_revision, kind)
      );

      create table if not exists session_read_state (
        session_id text not null references sessions(id) on delete cascade,
        reader_id text not null,
        last_seen_sequence integer not null default 0,
        manually_unread integer not null default 0 check(manually_unread in (0, 1)),
        updated_at text not null,
        primary key(session_id, reader_id)
      );

      create index if not exists session_attention_events_unread_idx
        on session_attention_events(session_id, sequence, has_error);
    `,
    run: (sqlite) => {
      sqlite.exec(`
        insert into session_attention_state (session_id, current_mode_id)
        select s.id, (
          select json_extract(se.payload, '$.modeId')
          from session_events se
          where se.session_id = s.id
            and se.kind = 'session.updated'
            and json_type(se.payload, '$.modeId') = 'text'
          order by se.revision desc limit 1
        )
        from sessions s
        where exists (
          select 1 from session_events se
          where se.session_id = s.id
            and se.kind = 'session.updated'
            and json_type(se.payload, '$.modeId') = 'text'
        )
        on conflict(session_id) do update set current_mode_id = excluded.current_mode_id;
      `)
    }
  },
  {
    id: 32,
    name: "archive timestamps and worktree snapshots",
    /// `is_archived` becomes a derived mirror of `archived_at`: writers set both
    /// so a client from an older release still reads a correct flag, while the
    /// timestamp drives ordering ("archived 2d ago") and cascade provenance.
    ///
    /// `archive_cascade_from` records WHY a row was archived. Unarchiving a
    /// project must revive only the children that same cascade archived — a
    /// chat the user archived by hand weeks earlier stays archived.
    ///
    /// `archived_worktrees` outlives the `worktrees` row on purpose: archiving
    /// frees the worktree name back into the pool immediately, so restore is
    /// keyed by worktree id and remembers the name it would *like* to reclaim.
    sql: `
      alter table projects add column archived_at text;
      alter table workspaces add column archived_at text;
      alter table sessions add column archived_at text;

      alter table workspaces add column archive_cascade_from text;
      alter table sessions add column archive_cascade_from text;

      create table if not exists archived_worktrees (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        original_name text not null,
        branch text not null,
        parent_sha text not null,
        snapshot_ref text not null,
        created_at text not null
      );

      create index if not exists archived_worktrees_project_idx
        on archived_worktrees(project_id, server_id, original_name);

      create index if not exists sessions_archived_idx
        on sessions(project_id, archived_at);
    `,
    run: (sqlite) => {
      // Rows archived before this migration have no recorded moment. Stamp them
      // with the repo's oldest meaningful timestamp rather than "now" so the
      // archived list does not claim a years-old chat was archived today.
      sqlite.exec(`
        update projects set archived_at = coalesce(created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
        update workspaces set archived_at = coalesce(created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
        update sessions set archived_at = coalesce(updated_at, created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
      `)
    }
  },
  {
    id: 33,
    name: "drop workspace notes",
    /// The scratchpad feature (a per-workspace notes panel in the macOS
    /// inspector) is gone, so its storage goes with it. Migrations 22 and 30
    /// stay untouched — they already ran on existing installs, and a fresh
    /// database still creates the table there before this migration drops it.
    ///
    /// The stale `workspace.notes.updated` rows are purged too: the event kind
    /// has left the API vocabulary, and the log is replayed to clients from a
    /// cursor, so leaving them would fan out a kind nothing understands.
    sql: `
      drop table if exists workspace_notes;
      delete from events where kind = 'workspace.notes.updated';
    `
  }
]
