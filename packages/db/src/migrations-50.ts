import type { Migration } from "./migration-types.js"

export const migrations50: ReadonlyArray<Migration> = [
  {
    id: 50,
    name: "archive belongs to the workspace",
    // Archiving used to be three independent bits (project, workspace, chat)
    // plus `archive_cascade_from` provenance to undo the cascades. The bits
    // drifted from each other and from other clients, and a chat whose
    // provenance was cleared by an unrelated write could never be restored.
    //
    // The workspace is now the only archivable thing. A chat is CLOSED, which
    // means it has no `workspace_panes` row — state the server already owns and
    // already ships to every client (including a fresh install) in
    // `GET /v1/navigation`. Projects are deleted rather than archived.
    //
    // Existing intent is translated before the columns go, in this order.
    sql: `
      -- 1. An archived project archived everything under it. Push that down to
      --    the workspaces, which are now the unit that carries the state. Keep
      --    the project's own stamp where a workspace has none so the archive
      --    ordering users already see does not jump.
      update workspaces
        set is_archived = 1,
            archived_at = coalesce(
              archived_at,
              (select p.archived_at from projects p where p.id = workspaces.project_id collate nocase),
              created_at
            )
        where is_archived = 0
          and project_id in (select id from projects where is_archived = 1);

      -- 2. A chat archived ON ITS OWN becomes a closed tab. A chat archived by
      --    its workspace keeps its pane: the workspace carries the archive now,
      --    and un-archiving it must bring the same tabs back. "Archived by its
      --    workspace" is read from the workspace's own state rather than from
      --    archive_cascade_from, because unrelated writes could clear that
      --    provenance -- which is one of the bugs this migration retires.
      --
      --    Closing a tab already deleted the pane, so this is mostly a safety
      --    net for rows a stale client archived without removing the pane.
      delete from workspace_panes
        where resource_kind = 'session'
          and lower(resource_id) in (
            select lower(s.id)
              from sessions s
              left join workspaces w on w.id = s.workspace_id collate nocase
              where s.is_archived = 1 and coalesce(w.is_archived, 0) = 0
          );

      -- 3. The navigation trigger names sessions.is_archived in its WHEN
      --    clause, and every trigger is created "if not exists", so it would
      --    survive this migration and then fail against the dropped column.
      --    installNavigationJournal recreates it after the schema commit.
      drop trigger if exists navigation_sessions_update;

      -- 4. The only index over the archive columns. Dropping it first is what
      --    lets sessions.archived_at go.
      drop index if exists sessions_archived_idx;

      alter table sessions drop column is_archived;
      alter table sessions drop column archived_at;
      alter table sessions drop column archive_cascade_from;
      alter table projects drop column is_archived;
      alter table projects drop column archived_at;
      alter table workspaces drop column archive_cascade_from;

      -- 5. Archiving a worktree destroys files before it can finish recording
      --    what it destroyed. The state column lets the bookkeeping row be
      --    written FIRST, so an interrupted archive is a 'pending' row the boot
      --    reconciler can finish instead of an unreferenced snapshot ref and a
      --    worktrees row pointing at a directory that is already gone.
      alter table archived_worktrees add column state text not null default 'complete';
    `
  }
]
