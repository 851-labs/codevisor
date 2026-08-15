import type { Worktree } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { worktreePath } from "./paths.js"
import { archivedWorktreeFromRow, worktreeFromRow } from "./row-mappers.js"
import type { ArchivedWorktreeRow, WorktreeRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

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
          .prepare(
            `insert into worktrees (
              id, project_id, server_id, name, branch, created_at
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(worktree.id, projectId, worktree.serverId, name, branch, worktree.createdAt)
        return worktree
      }),
    listWorktrees: (projectId) =>
      attempt("listWorktrees", () =>
        (
          sqlite
            .prepare("select * from worktrees where project_id = ? order by created_at asc")
            .all(canonicalUuid(projectId)) as ReadonlyArray<WorktreeRow>
        ).map(worktreeFromRow)
      ),
    deleteWorktree: (id) =>
      attempt("deleteWorktree", () => {
        sqlite.prepare("delete from worktrees where id = ?").run(canonicalUuid(id))
      }),
    createArchivedWorktree: (record) =>
      attempt("createArchivedWorktree", () => {
        const id = canonicalUuid(record.id)
        sqlite
          .prepare(
            `insert into archived_worktrees (
               id, project_id, server_id, original_name, branch, parent_sha, snapshot_ref, created_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               original_name = excluded.original_name,
               branch = excluded.branch,
               parent_sha = excluded.parent_sha,
               snapshot_ref = excluded.snapshot_ref`
          )
          .run(
            id,
            canonicalUuid(record.projectId),
            record.serverId,
            record.originalName,
            record.branch,
            record.parentSha,
            record.snapshotRef,
            record.createdAt
          )
        return archivedWorktreeFromRow(
          sqlite
            .prepare("select * from archived_worktrees where id = ?")
            .get(id) as ArchivedWorktreeRow
        )
      }),
    /// Restore looks up by (project, server, name) because that is all an
    /// archived session carries — `worktree_name` is the only link left once
    /// the `worktrees` row is gone.
    findArchivedWorktree: (rawProjectId, serverId, originalName) =>
      attempt("findArchivedWorktree", () => {
        const row = sqlite
          .prepare(
            `select * from archived_worktrees
             where project_id = ? collate nocase and server_id = ? and original_name = ?
             order by created_at desc limit 1`
          )
          .get(canonicalUuid(rawProjectId), serverId, originalName) as
          | ArchivedWorktreeRow
          | undefined
        return row === undefined ? undefined : archivedWorktreeFromRow(row)
      }),
    listArchivedWorktrees: (rawProjectId) =>
      attempt("listArchivedWorktrees", () =>
        (
          sqlite
            .prepare(
              "select * from archived_worktrees where project_id = ? collate nocase order by created_at desc"
            )
            .all(canonicalUuid(rawProjectId)) as ReadonlyArray<ArchivedWorktreeRow>
        ).map(archivedWorktreeFromRow)
      ),
    deleteArchivedWorktree: (id) =>
      attempt("deleteArchivedWorktree", () => {
        sqlite.prepare("delete from archived_worktrees where id = ?").run(canonicalUuid(id))
      })
  }
}
