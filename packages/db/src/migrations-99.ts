import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import { sessionCheckoutPlace, type CheckoutPlace } from "./checkouts.js"
import { canonicalUuid } from "./ids.js"
import type { Migration } from "./migration-types.js"
import { worktreeNameAt } from "./paths.js"
import { nullable, rowReader, text } from "./row-reader.js"

const idRows = rowReader({ id: text })

const ensureCheckout = (sqlite: Database.Database, place: CheckoutPlace): string => {
  const existing = idRows.maybe(sqlite.prepare(backfillSql.byPlace).get(place.serverId, place.path))
  if (existing !== undefined) return existing.id

  const id = randomUUID()
  const projectId = canonicalUuid(place.projectId)
  const worktreeName = place.worktreeName ?? worktreeNameAt(place.projectId, place.path)
  const worktree =
    worktreeName === undefined
      ? undefined
      : idRows.maybe(
          sqlite.prepare(backfillSql.worktreeId).get(projectId, place.serverId, worktreeName)
        )
  sqlite
    .prepare(backfillSql.insert)
    .run(
      id,
      place.serverId,
      projectId,
      worktree?.id ?? null,
      worktreeName ?? null,
      place.path,
      isoTimestamp()
    )
  return id
}

const workspaceRootRows = rowReader({
  id: text,
  server_id: text,
  project_id: text,
  root_directory: text,
  git_branch: nullable(text),
  git_detached_head: nullable(text),
  git_pull_request: nullable(text)
})

type WorkspaceRoot = ReturnType<typeof workspaceRootRows.one>

const sessionPlaceRows = rowReader({
  id: text,
  server_id: text,
  project_id: text,
  worktree_name: nullable(text),
  folder_path: nullable(text)
})

const knowsGit = (workspace: WorkspaceRoot): boolean =>
  workspace.git_branch !== null ||
  workspace.git_detached_head !== null ||
  workspace.git_pull_request !== null

const backfillWorkspaces = (sqlite: Database.Database): void => {
  for (const workspace of workspaceRootRows.all(sqlite.prepare(backfillSql.workspaceRoots).all())) {
    const checkoutId = ensureCheckout(sqlite, {
      serverId: workspace.server_id,
      projectId: workspace.project_id,
      path: workspace.root_directory
    })
    if (knowsGit(workspace)) {
      sqlite
        .prepare(backfillSql.copyGit)
        .run(
          workspace.git_branch,
          workspace.git_detached_head,
          workspace.git_pull_request,
          checkoutId
        )
    }
    sqlite.prepare(backfillSql.setWorkspaceDefault).run(checkoutId, workspace.id)
  }
}

const backfillSessions = (sqlite: Database.Database): void => {
  for (const session of sessionPlaceRows.all(sqlite.prepare(backfillSql.sessionPlaces).all())) {
    const place = sessionCheckoutPlace(
      session.server_id,
      session.project_id,
      session.folder_path ?? undefined,
      session.worktree_name ?? undefined
    )
    if (place === undefined) continue
    sqlite.prepare(backfillSql.setSessionCheckout).run(ensureCheckout(sqlite, place), session.id)
  }
}

export const migrations99: ReadonlyArray<Migration> = [
  {
    id: 99,
    name: "checkouts: where sessions and panes run, apart from the workspace that shows them",
    sql: `
      create table checkouts (
        id text primary key,
        server_id text not null,
        project_id text not null references projects(id) on delete cascade,
        worktree_id text,
        worktree_name text,
        path text not null,
        git_branch text,
        git_detached_head text,
        git_pull_request text,
        git_known integer not null default 0,
        created_at text not null,
        updated_at text,
        unique (server_id, path)
      );
      alter table workspaces add column default_checkout_id text references checkouts(id) on delete set null;
      alter table sessions add column checkout_id text references checkouts(id) on delete set null;
      alter table workspace_panes add column checkout_id text references checkouts(id) on delete set null;
      alter table workspace_panes add column resource_server_id text;
      create index sessions_checkout_idx on sessions(checkout_id);
      create index workspace_panes_checkout_idx on workspace_panes(checkout_id);
    `,
    run: (sqlite) => {
      backfillWorkspaces(sqlite)
      backfillSessions(sqlite)
      sqlite.exec(backfillSql.defaultsFromMainSession)
      sqlite.exec(backfillSql.sessionPaneCheckouts)
      sqlite.exec(backfillSql.otherPaneCheckouts)
    }
  }
]

const backfillSql = {
  byPlace: "select id from checkouts where server_id = ? and path = ?",
  worktreeId: "select id from worktrees where project_id = ? and server_id = ? and name = ?",
  insert: `insert into checkouts (
      id, server_id, project_id, worktree_id, worktree_name, path, created_at
    ) values (?, ?, ?, ?, ?, ?, ?)`,
  workspaceRoots: `select id, server_id, project_id, root_directory, git_branch, git_detached_head, git_pull_request
      from workspaces where root_directory is not null order by is_archived desc, created_at, id`,
  copyGit: `update checkouts set git_branch = ?, git_detached_head = ?, git_pull_request = ?, git_known = 1
      where id = ?`,
  setWorkspaceDefault: "update workspaces set default_checkout_id = ? where id = ?",
  sessionPlaces: `select sessions.id, sessions.server_id, sessions.project_id, sessions.worktree_name,
        project_locations.folder_path
      from sessions
      left join project_locations
        on project_locations.project_id = sessions.project_id
        and project_locations.server_id = sessions.server_id
      order by sessions.created_at, sessions.id`,
  setSessionCheckout: "update sessions set checkout_id = ? where id = ?",
  defaultsFromMainSession: `update workspaces set default_checkout_id = (
        select checkout_id from sessions where sessions.id = workspaces.main_session_id
      ) where default_checkout_id is null and main_session_id is not null`,
  sessionPaneCheckouts: `update workspace_panes set checkout_id = (
        select checkout_id from sessions where sessions.id = workspace_panes.resource_id
      ) where resource_kind = 'session'`,
  otherPaneCheckouts: `update workspace_panes set checkout_id = (
        select default_checkout_id from workspaces where workspaces.id = workspace_panes.workspace_id
      ) where checkout_id is null`
}
