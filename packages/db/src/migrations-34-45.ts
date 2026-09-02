import { parseJsonRecord, sessionPlanFromPayload } from "./event-payloads.js"
import type { Migration } from "./migration-types.js"

/// Schema migrations 34–45.
export const migrations34To45: ReadonlyArray<Migration> = [
  {
    id: 34,
    name: "stable native sidebar state ordering",
    sql: `
      alter table sessions add column sidebar_state text not null default 'idle'
        check(sidebar_state in ('idle', 'inProgress', 'waitingForUser', 'unread', 'errored'));
      alter table sessions add column sidebar_state_changed_at text not null default '';

      update sessions
      set sidebar_state =
        case
          when exists (
            select 1 from session_attention_events ae
            where ae.session_id = sessions.id and ae.has_error = 1
              and ae.sequence > coalesce((
                select last_seen_sequence from session_read_state rs
                where rs.session_id = sessions.id and rs.reader_id = 'owner'
              ), 0)
          ) then 'errored'
          when pending_question is not null or coalesce((
            select pending_plan_approval from session_attention_state ast
            where ast.session_id = sessions.id
          ), 0) = 1 then 'waitingForUser'
          when coalesce((
            select turn_active from session_attention_state ast
            where ast.session_id = sessions.id
          ), 0) = 1
            or coalesce((
              select case when has_runtime_state = 1 and runtime_state = 'running' then 1 else 0 end
              from session_attention_state ast where ast.session_id = sessions.id
            ), 0) = 1
            or exists (
              select 1 from json_each(sessions.background_tasks)
              where json_extract(value, '$.terminalKey') is null
            ) then 'inProgress'
          when exists (
            select 1 from session_attention_events ae
            where ae.session_id = sessions.id
              and ae.sequence > coalesce((
                select last_seen_sequence from session_read_state rs
                where rs.session_id = sessions.id and rs.reader_id = 'owner'
              ), 0)
          ) or coalesce((
            select manually_unread from session_read_state rs
            where rs.session_id = sessions.id and rs.reader_id = 'owner'
          ), 0) = 1 then 'unread'
          else 'idle'
        end,
        sidebar_state_changed_at = coalesce(updated_at, created_at);
    `
  },
  {
    id: 35,
    name: "server owned workspace panes",
    sql: `
      create table workspace_panes (
        id text primary key,
        workspace_id text not null references workspaces(id) on delete cascade,
        provider_id text not null,
        pane_type text not null,
        title text not null,
        resource_kind text,
        resource_id text,
        metadata text check(metadata is null or json_valid(metadata)),
        created_at text not null,
        updated_at text,
        check((resource_kind is null) = (resource_id is null))
      );

      create index workspace_panes_workspace_idx
        on workspace_panes(workspace_id, created_at);
      create unique index workspace_panes_resource_idx
        on workspace_panes(workspace_id, resource_kind, resource_id)
        where resource_kind is not null and resource_id is not null;
      create unique index workspace_panes_session_resource_idx
        on workspace_panes(resource_kind, resource_id)
        where resource_kind = 'session';

      -- Session membership was the old implicit chat-pane registry. Promote
      -- every active assignment so upgraded clients see exactly the tabs an
      -- older client had already shared.
      insert into workspace_panes (
        id, workspace_id, provider_id, pane_type, title,
        resource_kind, resource_id, metadata, created_at, updated_at
      )
      select lower(s.id), lower(s.workspace_id), 'codevisor', 'chat',
        case when s.title = '' then 'Chat' else s.title end,
        'session', lower(s.id), null, s.created_at, s.updated_at
      from sessions s
      where s.workspace_id is not null and s.is_archived = 0;
    `
  },
  {
    id: 36,
    name: "revisioned workspace pane content",
    sql: `
      alter table workspace_panes add column revision integer not null default 1;
    `
  },
  {
    id: 37,
    name: "attention transcript receipt targets",
    sql: `
      alter table session_attention_events add column chat_item_id text
        references chat_items(id) on delete set null;

      update session_attention_events as ae
      set chat_item_id = coalesce(
        (
          select se.chat_item_id from session_events se
          where se.session_id = ae.session_id
            and se.revision = ae.source_revision
        ),
        case when ae.kind = 'finished' then (
          select se.chat_item_id
          from session_events se
          join chat_items ci on ci.id = se.chat_item_id and ci.role = 'assistant'
          where se.session_id = ae.session_id
            and se.revision <= ae.source_revision
            and json_extract(se.payload, '$.turnState') = 'started'
            and se.revision > coalesce((
              select max(previous.source_revision)
              from session_attention_events previous
              where previous.session_id = ae.session_id
                and previous.sequence < ae.sequence
            ), 0)
          order by se.revision desc
          limit 1
        ) end
      );
    `
  },
  {
    id: 38,
    name: "project worktree base branch",
    sql: `
      alter table projects add column worktree_base_remote text;
      alter table projects add column worktree_base_branch text;
    `
  },
  {
    id: 39,
    name: "remove dynamic entity icons",
    sql: `
      alter table projects drop column symbol_name;
      alter table workspaces drop column symbol_name;
    `
  },
  {
    id: 40,
    name: "remove persisted plugin icons",
    sql: `
      update workspace_panes
      set metadata = null
      where provider_id like 'plugin:%';
    `
  },
  {
    id: 41,
    name: "reorderable session prompt queue",
    sql: `
      alter table prompt_queue_items add column position integer not null default 0;

      with ranked as (
        select rowid as queue_rowid,
          row_number() over (
            partition by session_id, state
            order by created_at asc, rowid asc
          ) - 1 as queue_position
        from prompt_queue_items
      )
      update prompt_queue_items
      set position = (
        select queue_position from ranked
        where ranked.queue_rowid = prompt_queue_items.rowid
      );

      create index prompt_queue_items_session_state_position_idx
        on prompt_queue_items(session_id, state, position, created_at);
    `
  },
  {
    id: 42,
    name: "revision-counter session attention",
    /// Replaces the attention-event ledger + pending-epoch reducer with a
    /// single monotonic revision counter per session. Unread = revision ahead
    /// of the shared read cursor (`session_read_state` survives unchanged —
    /// its `last_seen_sequence` points into the same sequence space, so
    /// existing cursors carry over exactly). `errored` becomes an intrinsic
    /// flag (the urgent flavor of the action-required tier) instead of a
    /// property of unread ledger rows. `pending_finish`/`settle_due_at` park a
    /// finished turn while a subagent or goal still holds it in progress.
    sql: `
      create table session_attention (
        session_id text primary key references sessions(id) on delete cascade,
        attention_revision integer not null default 0,
        turn_active integer not null default 0 check(turn_active in (0, 1)),
        runtime_state text not null default 'idle'
          check(runtime_state in ('running', 'idle', 'requires_action')),
        has_runtime_state integer not null default 0 check(has_runtime_state in (0, 1)),
        current_mode_id text,
        pending_plan_approval integer not null default 0
          check(pending_plan_approval in (0, 1)),
        errored integer not null default 0 check(errored in (0, 1)),
        pending_finish integer not null default 0 check(pending_finish in (0, 1)),
        settle_due_at text
      );

      insert into session_attention (
        session_id, attention_revision, turn_active, runtime_state, has_runtime_state,
        current_mode_id, pending_plan_approval, errored, pending_finish
      )
      select s.id,
        coalesce((
          select max(ae.sequence) from session_attention_events ae where ae.session_id = s.id
        ), 0),
        coalesce(ast.turn_active, 0),
        coalesce(ast.runtime_state, 'idle'),
        coalesce(ast.has_runtime_state, 0),
        ast.current_mode_id,
        coalesce(ast.pending_plan_approval, 0),
        case when exists (
          select 1 from session_attention_events ae
          where ae.session_id = s.id and ae.has_error = 1
            and ae.sequence > coalesce((
              select last_seen_sequence from session_read_state rs
              where rs.session_id = s.id and rs.reader_id = 'owner'
            ), 0)
        ) then 1 else 0 end,
        -- Sessions the old reducer left holding an unreleased epoch — most
        -- prominently every "dev server pinned this chat inProgress forever"
        -- case — become a parked finish that restart recovery settles.
        coalesce(ast.pending_epoch, 0)
      from sessions s
      left join session_attention_state ast on ast.session_id = s.id;

      drop index if exists session_attention_events_unread_idx;
      drop table if exists session_attention_events;
      drop table if exists session_attention_state;
    `,
    run: (sqlite) => {
      // Recompute the denormalized sidebar snapshot under the new precedence,
      // bumping the ordering clock only where the visible value changed.
      const nextState = `
        case
          when (select errored from session_attention sa where sa.session_id = sessions.id) = 1
            then 'errored'
          when sessions.pending_question is not null
            or (select pending_plan_approval from session_attention sa
                where sa.session_id = sessions.id) = 1
            then 'waitingForUser'
          when (select turn_active from session_attention sa where sa.session_id = sessions.id) = 1
            or (select pending_finish from session_attention sa
                where sa.session_id = sessions.id) = 1
            or exists (
              select 1 from json_each(sessions.background_tasks)
              where json_extract(value, '$.taskType') = 'subagent'
            )
            or (select case when has_runtime_state = 1 and runtime_state = 'running'
                  then 1 else 0 end
                from session_attention sa where sa.session_id = sessions.id) = 1
            then 'inProgress'
          when coalesce((
              select manually_unread from session_read_state rs
              where rs.session_id = sessions.id and rs.reader_id = 'owner'
            ), 0) = 1
            or (select attention_revision from session_attention sa
                where sa.session_id = sessions.id) > coalesce((
              select last_seen_sequence from session_read_state rs
              where rs.session_id = sessions.id and rs.reader_id = 'owner'
            ), 0)
            then 'unread'
          else 'idle'
        end`
      sqlite.exec(`
        update sessions
        set sidebar_state_changed_at = case
              when sidebar_state = (${nextState}) then sidebar_state_changed_at
              else coalesce(updated_at, created_at, sidebar_state_changed_at)
            end,
            sidebar_state = (${nextState});
      `)
    }
  },
  {
    id: 43,
    name: "config-plane sync entries",
    sql: `
      create table if not exists sync_entries (
        namespace text not null,
        key text not null,
        value text not null,
        deleted integer not null default 0,
        ts_wall integer not null,
        ts_counter integer not null,
        ts_device text not null,
        primary key (namespace, key)
      );
    `
  },
  {
    id: 44,
    name: "machine-readable turn stop kind",
    sql: `
      alter table chat_items add column stop_kind text;
    `
  },
  {
    id: 45,
    name: "durable session checklists",
    sql: `
      alter table sessions add column session_plan text;
    `,
    run: (sqlite) => {
      // Plans are full snapshots. Walk newest-first and retain the first valid
      // one for each session so existing chats gain durable cross-device
      // checklist state immediately after the upgrade.
      const restored = new Set<string>()
      const candidates = sqlite
        .prepare(
          `select session_id, payload from session_events
           where kind = 'session.output'
             and json_valid(payload)
             and json_extract(payload, '$.sessionUpdate') = 'plan'
           order by session_id, revision desc`
        )
        .all() as ReadonlyArray<{ readonly session_id: string; readonly payload: string }>
      const update = sqlite.prepare("update sessions set session_plan = ? where id = ?")
      for (const candidate of candidates) {
        if (restored.has(candidate.session_id)) continue
        // The SQL predicates guarantee a JSON object with sessionUpdate.
        const payload = parseJsonRecord(candidate.payload)!
        const plan = sessionPlanFromPayload(payload)
        if (plan === undefined) continue
        update.run(JSON.stringify(plan), candidate.session_id)
        restored.add(candidate.session_id)
      }
    }
  }
]
