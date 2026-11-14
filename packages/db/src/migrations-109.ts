import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { Migration } from "./migration-types.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"

const checkoutRows = rowReader({
  id: text,
  server_id: text,
  project_id: text,
  worktree_name: text,
  path: text,
  created_at: text
})

type SharedCheckout = ReturnType<typeof checkoutRows.one>

const lifeRows = rowReader({ id: text, branch: text, created_at: text })

type Life = ReturnType<typeof lifeRows.one>

const liveRows = rowReader({ id: text, created_at: text })

const workspaceRows = rowReader({
  id: text,
  is_archived: integer,
  archived_at: nullable(text),
  git_branch: nullable(text),
  git_detached_head: nullable(text),
  git_pull_request: nullable(text),
  git_known: integer
})

type WorkspaceUse = ReturnType<typeof workspaceRows.one>

const sessionRows = rowReader({
  id: text,
  is_archived: integer,
  archived_at: nullable(text),
  workspace_id: nullable(text)
})

const paneRows = rowReader({
  id: text,
  workspace_id: text,
  resource_kind: nullable(text),
  resource_id: nullable(text),
  is_archived: integer,
  archived_at: nullable(text)
})

interface Closed {
  readonly is_archived: number
  readonly archived_at: string | null
}

interface Group {
  readonly life: Life | undefined
  readonly retiredAt: string
  readonly workspaces: Array<WorkspaceUse>
  readonly sessions: Array<string>
  readonly panes: Array<string>
}

const current = "current"

const archiveLagMs = 60 * 60 * 1000

const lifeEndedBy = (lives: ReadonlyArray<Life>, archivedAt: string): Life | undefined => {
  const closed = Date.parse(archivedAt)
  return lives.find((life) => {
    const ended = Date.parse(life.created_at)
    return ended >= closed - 1000 && ended <= closed + archiveLagMs
  })
}

const splitCheckout = (sqlite: Database.Database, shared: SharedCheckout): void => {
  const place = [shared.project_id, shared.server_id, shared.worktree_name]
  const lives = lifeRows.all(sqlite.prepare(splitSql.lives).all(...place))
  const live = liveRows.maybe(sqlite.prepare(splitSql.live).get(...place))
  const groups = new Map<string, Group>()
  const groupOf = (key: string, life: Life | undefined, retiredAt: string): Group => {
    const existing = groups.get(key)
    if (existing !== undefined) return existing
    const group: Group = { life, retiredAt, workspaces: [], sessions: [], panes: [] }
    groups.set(key, group)
    return group
  }
  const keyFor = (use: Closed, owner: string): string => {
    if (use.is_archived !== 1 || use.archived_at === null) return current
    const life = lifeEndedBy(lives, use.archived_at)
    if (life !== undefined) {
      groupOf(life.id, life, life.created_at)
      return life.id
    }
    if (live !== undefined && Date.parse(live.created_at) <= Date.parse(use.archived_at))
      return current
    groupOf(owner, undefined, use.archived_at)
    return owner
  }

  const workspaceKeys = new Map<string, string>()
  for (const workspace of workspaceRows.all(sqlite.prepare(splitSql.workspaces).all(shared.id))) {
    const key = keyFor(workspace, `workspace:${workspace.id}`)
    workspaceKeys.set(workspace.id, key)
    groups.get(key)?.workspaces.push(workspace)
  }
  const sessionKeys = new Map<string, string>()
  for (const session of sessionRows.all(sqlite.prepare(splitSql.sessions).all(shared.id))) {
    const key =
      (session.workspace_id === null ? undefined : workspaceKeys.get(session.workspace_id)) ??
      keyFor(session, `workspace:${session.workspace_id ?? session.id}`)
    sessionKeys.set(session.id, key)
    groups.get(key)?.sessions.push(session.id)
  }
  for (const pane of paneRows.all(sqlite.prepare(splitSql.panes).all(shared.id))) {
    const key =
      (pane.resource_kind === "session" && pane.resource_id !== null
        ? sessionKeys.get(pane.resource_id)
        : undefined) ??
      workspaceKeys.get(pane.workspace_id) ??
      keyFor(pane, `workspace:${pane.workspace_id}`)
    groups.get(key)?.panes.push(pane.id)
  }

  for (const group of groups.values()) moveToOwnCheckout(sqlite, shared, group)
  if (live === undefined) sqlite.prepare(splitSql.retire).run(isoTimestamp(), shared.id)
  else sqlite.prepare(splitSql.adopt).run(live.id, shared.id)
}

const moveToOwnCheckout = (
  sqlite: Database.Database,
  shared: SharedCheckout,
  group: Group
): void => {
  const id = randomUUID()
  const known = group.workspaces
    .filter((workspace) => workspace.git_known === 1)
    .toSorted((a, b) => (b.archived_at ?? "").localeCompare(a.archived_at ?? ""))[0]
  sqlite.prepare(splitSql.insert).run({
    id,
    serverId: shared.server_id,
    projectId: shared.project_id,
    worktreeId: group.life?.id ?? null,
    worktreeName: shared.worktree_name,
    path: shared.path,
    branch: known === undefined ? (group.life?.branch ?? null) : known.git_branch,
    detachedHead: known?.git_detached_head ?? null,
    pullRequest: known?.git_pull_request ?? null,
    gitKnown: known === undefined && group.life === undefined ? 0 : 1,
    createdAt: shared.created_at,
    retiredAt: group.retiredAt
  })
  for (const workspace of group.workspaces)
    sqlite.prepare(splitSql.moveWorkspace).run(id, workspace.id)
  for (const session of group.sessions) sqlite.prepare(splitSql.moveSession).run(id, session)
  for (const pane of group.panes) sqlite.prepare(splitSql.movePane).run(id, pane)
}

export const migrations109: ReadonlyArray<Migration> = [
  {
    id: 109,
    name: "checkouts: one per worktree, retired when the worktree is archived, so a reused name starts a new one",
    sql: `
      create table checkouts_next (
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
        retired_at text
      );
      insert into checkouts_next select
        id, server_id, project_id, worktree_id, worktree_name, path, git_branch, git_detached_head,
        git_pull_request, git_known, created_at, updated_at, null
        from checkouts;
      drop table checkouts;
      alter table checkouts_next rename to checkouts;
      create unique index checkouts_current_place_idx
        on checkouts(server_id, path) where retired_at is null;
      create index checkouts_worktree_idx on checkouts(worktree_id);
    `,
    run: (sqlite) => {
      for (const shared of checkoutRows.all(sqlite.prepare(splitSql.worktreeCheckouts).all()))
        splitCheckout(sqlite, shared)
      sqlite.exec(splitSql.dropUnused)
      sqlite.exec(splitSql.takeKnownGit)
    }
  }
]

const knownWorkspace = (column: string): string =>
  `(select ${column} from workspaces
      where workspaces.default_checkout_id = checkouts.id and workspaces.git_known = 1
      order by workspaces.is_archived, coalesce(workspaces.updated_at, workspaces.created_at) desc,
        workspaces.id
      limit 1)`

const splitSql = {
  takeKnownGit: `update checkouts set
        git_branch = ${knownWorkspace("git_branch")},
        git_detached_head = ${knownWorkspace("git_detached_head")},
        git_pull_request = ${knownWorkspace("git_pull_request")},
        git_known = 1
      where git_known = 0
        and exists (
          select 1 from workspaces
          where workspaces.default_checkout_id = checkouts.id and workspaces.git_known = 1
        )`,
  worktreeCheckouts: `select id, server_id, project_id, worktree_name, path, created_at
      from checkouts where worktree_name is not null order by created_at, id`,
  lives: `select id, branch, created_at from archived_worktrees
      where project_id = ? collate nocase and server_id = ? and original_name = ?
      order by created_at, id`,
  live: `select id, created_at from worktrees
      where project_id = ? collate nocase and server_id = ? and name = ?`,
  workspaces: `select id, is_archived, archived_at, git_branch, git_detached_head, git_pull_request,
        git_known
      from workspaces where default_checkout_id = ? order by created_at, id`,
  sessions: `select id, is_archived, archived_at, workspace_id from sessions
      where checkout_id = ? order by created_at, id`,
  panes: `select workspace_panes.id, workspace_panes.workspace_id, workspace_panes.resource_kind,
        workspace_panes.resource_id, workspaces.is_archived, workspaces.archived_at
      from workspace_panes join workspaces on workspaces.id = workspace_panes.workspace_id
      where workspace_panes.checkout_id = ? order by workspace_panes.created_at, workspace_panes.id`,
  insert: `insert into checkouts (
        id, server_id, project_id, worktree_id, worktree_name, path, git_branch, git_detached_head,
        git_pull_request, git_known, created_at, retired_at
      ) values (
        @id, @serverId, @projectId, @worktreeId, @worktreeName, @path, @branch, @detachedHead,
        @pullRequest, @gitKnown, @createdAt, @retiredAt
      )`,
  moveWorkspace: "update workspaces set default_checkout_id = ? where id = ?",
  moveSession: "update sessions set checkout_id = ? where id = ?",
  movePane: "update workspace_panes set checkout_id = ? where id = ?",
  retire: "update checkouts set retired_at = ? where id = ? and retired_at is null",
  adopt: "update checkouts set worktree_id = ? where id = ?",
  dropUnused: `delete from checkouts
      where retired_at is not null and worktree_id is null
        and not exists (select 1 from workspaces where default_checkout_id = checkouts.id)
        and not exists (select 1 from sessions where checkout_id = checkouts.id)
        and not exists (select 1 from workspace_panes where checkout_id = checkouts.id)`
}
