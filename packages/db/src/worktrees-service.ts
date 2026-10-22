import { randomUUID } from "node:crypto"

import type { Worktree } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { worktreePath } from "./paths.js"
import { archivedWorktreeFromRow, worktreeFromRow } from "./row-mappers.js"
import { archivedWorktreeRows, worktreeRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeWorktreesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createWorktree"
  | "listWorktrees"
  | "deleteWorktree"
  | "createArchivedWorktree"
  | "findArchivedWorktree"
  | "listArchivedWorktrees"
  | "deleteArchivedWorktree"
> => {
  const { sqlite, config, getProject } = context

  return {
    createWorktree: (rawProjectId, name, branch, id) =>
      attempt("createWorktree", () => {
        const projectId = canonicalUuid(rawProjectId)
        getProject(projectId)
        const worktree: Worktree = {
          id: (id ?? randomUUID()).toLowerCase(),
          projectId,
          serverId: config.serverId,
          name,
          branch,
          path: worktreePath(projectId, name),
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(worktreeSql.insert)
          .run(worktree.id, projectId, worktree.serverId, name, branch, worktree.createdAt)
        return worktree
      }),
    listWorktrees: (projectId) =>
      attempt("listWorktrees", () => projectWorktrees(sqlite, projectId).map(worktreeFromRow)),
    deleteWorktree: (id) =>
      attempt("deleteWorktree", () => {
        sqlite.prepare(worktreeSql.delete).run(canonicalUuid(id))
      }),
    createArchivedWorktree: (record) =>
      attempt("createArchivedWorktree", () => {
        const id = canonicalUuid(record.id)
        sqlite
          .prepare(archivedWorktreeSql.upsert)
          .run(
            id,
            canonicalUuid(record.projectId),
            record.serverId,
            record.originalName,
            record.branch,
            record.parentSha,
            record.snapshotRef,
            record.createdAt,
            record.state
          )
        return archivedWorktreeFromRow(savedArchivedWorktree(sqlite, id))
      }),
    findArchivedWorktree: (rawProjectId, serverId, originalName) =>
      attempt("findArchivedWorktree", () => {
        const row = latestArchivedWorktree(sqlite, rawProjectId, serverId, originalName)
        return row === undefined ? undefined : archivedWorktreeFromRow(row)
      }),
    listArchivedWorktrees: (rawProjectId) =>
      attempt("listArchivedWorktrees", () =>
        projectArchivedWorktrees(sqlite, rawProjectId).map(archivedWorktreeFromRow)
      ),
    deleteArchivedWorktree: (id) =>
      attempt("deleteArchivedWorktree", () => {
        sqlite.prepare(archivedWorktreeSql.delete).run(canonicalUuid(id))
      })
  }
}

const projectWorktrees = (sqlite: ServiceContext["sqlite"], rawProjectId: string) =>
  worktreeRows.all(sqlite.prepare(worktreeSql.byProject).all(canonicalUuid(rawProjectId)))

const savedArchivedWorktree = (sqlite: ServiceContext["sqlite"], id: string) =>
  archivedWorktreeRows.one(sqlite.prepare(archivedWorktreeSql.byId).get(id))

const latestArchivedWorktree = (
  sqlite: ServiceContext["sqlite"],
  rawProjectId: string,
  serverId: string,
  originalName: string
) =>
  archivedWorktreeRows.maybe(
    sqlite
      .prepare(archivedWorktreeSql.latestByName)
      .get(canonicalUuid(rawProjectId), serverId, originalName)
  )

const projectArchivedWorktrees = (sqlite: ServiceContext["sqlite"], rawProjectId: string) =>
  archivedWorktreeRows.all(
    sqlite.prepare(archivedWorktreeSql.byProject).all(canonicalUuid(rawProjectId))
  )

const worktreeSql = {
  insert: `insert into worktrees (
              id, project_id, server_id, name, branch, created_at
            ) values (?, ?, ?, ?, ?, ?)`,
  byProject: "select * from worktrees where project_id = ? order by created_at asc",
  delete: "delete from worktrees where id = ?"
}

const archivedWorktreeSql = {
  upsert: `insert into archived_worktrees (
               id, project_id, server_id, original_name, branch, parent_sha, snapshot_ref,
               created_at, state
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               original_name = excluded.original_name,
               branch = excluded.branch,
               parent_sha = excluded.parent_sha,
               snapshot_ref = excluded.snapshot_ref,
               state = excluded.state`,
  byId: "select * from archived_worktrees where id = ?",
  latestByName: `select * from archived_worktrees
             where project_id = ? collate nocase and server_id = ? and original_name = ?
             order by created_at desc limit 1`,
  byProject:
    "select * from archived_worktrees where project_id = ? collate nocase order by created_at desc",
  delete: "delete from archived_worktrees where id = ?"
}
