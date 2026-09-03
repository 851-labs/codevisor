import type { CreateProjectRequest, Project, ProjectLocation } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { projectFromRow } from "./row-mappers.js"
import type { ProjectRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"

export const makeProjectsService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  "createProject" | "listProjects" | "updateProject" | "deleteProject" | "setProjectRepoUrl"
> => {
  const { sqlite, config, locationRowsFor, getProject } = context

  /// Archiving a container archives the children that were still active, and
  /// stamps each with the container id that did it. Children already archived
  /// on their own are left completely untouched — including their original
  /// `archived_at` — so the later unarchive can tell the two groups apart.
  ///
  /// Callers must already hold a transaction (see updateProject).
  const cascadeArchiveProject = (projectId: string, stamp: string): void => {
    sqlite
      .prepare(
        `update workspaces set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where project_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, projectId, projectId)
    sqlite
      .prepare(
        `update sessions set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where project_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, projectId, projectId)
  }

  /// The exact inverse: revive only rows whose provenance names this project.
  /// A chat the user archived by hand before the project was archived has a
  /// null (or workspace-scoped) `archive_cascade_from` and stays archived.
  const cascadeUnarchiveProject = (projectId: string): void => {
    sqlite
      .prepare(
        `update workspaces set is_archived = 0, archived_at = null, archive_cascade_from = null
         where project_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(projectId, projectId)
    sqlite
      .prepare(
        `update sessions set is_archived = 0, archived_at = null, archive_cascade_from = null
         where project_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(projectId, projectId)
  }

  const createProject = Effect.fn("CodevisorDatabase.createProject")(function* (
    request: CreateProjectRequest
  ) {
    return yield* attempt("createProject", () => {
      const now = isoTimestamp()
      // UUIDs are case-insensitive identifiers. Canonicalize to lowercase on
      // write so ids stay consistent no matter which client created them
      // (Swift uppercases, Node lowercases) — a case-only difference must not
      // spawn a duplicate project or merge one into a differently-cased row.
      const projectId = (request.id ?? randomUUID()).toLowerCase()
      const createdAt = request.createdAt ?? now

      // Idempotency: re-creating an existing project id returns it.
      const byId = sqlite
        .prepare("select id from projects where id = ? collate nocase")
        .get(projectId) as { id: string } | undefined
      if (byId !== undefined) {
        return getProject(byId.id)
      }

      // A folder maps to exactly one project per server. If this folder is
      // already claimed under a different project id (stale data, another
      // client), merge that project into the requested id instead of failing
      // on the unique(server_id, folder_path) constraint — its sessions and
      // worktrees come along.
      const claimed = sqlite
        .prepare("select project_id from project_locations where server_id = ? and folder_path = ?")
        .get(config.serverId, request.folderPath) as { project_id: string } | undefined
      if (claimed !== undefined) {
        if (request.id === undefined || claimed.project_id.toLowerCase() === projectId) {
          return getProject(claimed.project_id)
        }
        const claimedProject = getProject(claimed.project_id)
        const merge = sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into projects (
                id, name, is_archived, origin, created_at, repo_url,
                worktree_base_remote, worktree_base_branch
              ) values (?, ?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
              projectId,
              request.name ?? basename(request.folderPath),
              (request.isArchived ?? false) ? 1 : 0,
              request.origin ?? "codevisor",
              createdAt,
              request.repoUrl ?? null,
              claimedProject.worktreeBase?.remote ?? null,
              claimedProject.worktreeBase?.branch ?? null
            )
          for (const table of ["project_locations", "sessions", "worktrees"]) {
            sqlite
              .prepare(`update ${table} set project_id = ? where project_id = ?`)
              .run(projectId, claimed.project_id)
          }
          sqlite.prepare("delete from projects where id = ?").run(claimed.project_id)
        })
        merge()
        return getProject(projectId)
      }
      const location: ProjectLocation = {
        id: randomUUID(),
        projectId,
        serverId: config.serverId,
        folderPath: request.folderPath,
        createdAt
      }
      const project: Project = {
        id: projectId,
        name: request.name ?? basename(request.folderPath),
        isArchived: request.isArchived ?? false,
        origin: request.origin ?? "codevisor",
        createdAt,
        locations: [location],
        ...(request.repoUrl === undefined ? {} : { repoUrl: request.repoUrl })
      }
      const transaction = sqlite.transaction(() => {
        sqlite
          .prepare(
            `insert into projects (
              id, name, is_archived, origin, created_at, repo_url,
              worktree_base_remote, worktree_base_branch
            ) values (?, ?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            project.id,
            project.name,
            project.isArchived ? 1 : 0,
            project.origin,
            project.createdAt,
            project.repoUrl ?? null,
            null,
            null
          )
        sqlite
          .prepare(
            `insert into project_locations (
              id, project_id, server_id, folder_path, created_at
            ) values (?, ?, ?, ?, ?)`
          )
          .run(
            location.id,
            location.projectId,
            location.serverId,
            location.folderPath,
            location.createdAt
          )
      })
      transaction()
      return project
    })
  })

  return {
    createProject,
    listProjects: attempt("listProjects", () =>
      sqlite
        .prepare("select * from projects order by created_at desc")
        .all()
        .map((row) => projectFromRow(row as ProjectRow, locationRowsFor((row as ProjectRow).id)))
    ),
    updateProject: (id, request) =>
      attempt("updateProject", () => {
        const current = getProject(id)
        // `archivedStamp` returns a moment exactly when the row ends up
        // archived, so the stamp carries the resulting state too: deriving
        // the flag and both transitions from it keeps them consistent by
        // construction rather than by three parallel conditions.
        const stamp = archivedStamp(request.isArchived, current.isArchived, current.archivedAt)
        const worktreeBase =
          request.worktreeBase === undefined
            ? current.worktreeBase
            : (request.worktreeBase ?? undefined)
        const archiving = stamp !== null && !current.isArchived
        const unarchiving = stamp === null && current.isArchived
        // One transaction so a cascade can never half-apply: a project that
        // reads as archived while its sessions still read as active would
        // strand those chats in no sidebar section at all.
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `update projects set name = ?, is_archived = ?, archived_at = ?,
                worktree_base_remote = ?, worktree_base_branch = ?
               where id = ? collate nocase`
            )
            .run(
              request.name ?? current.name,
              stamp === null ? 0 : 1,
              stamp,
              worktreeBase?.remote ?? null,
              worktreeBase?.branch ?? null,
              id
            )
          if (stamp !== null && archiving) {
            cascadeArchiveProject(id, stamp)
          } else if (unarchiving) {
            cascadeUnarchiveProject(id)
          }
        })()
        return getProject(id)
      }),
    setProjectRepoUrl: (id, repoUrl) =>
      attempt("setProjectRepoUrl", () => {
        const result = sqlite
          .prepare("update projects set repo_url = ? where id = ? collate nocase")
          .run(repoUrl, id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
        return getProject(id)
      }),
    deleteProject: (id) =>
      attempt("deleteProject", () => {
        const result = sqlite.prepare("delete from projects where id = ? collate nocase").run(id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
      })
  }
}

const basename = (path: string): string => path.split("/").filter(Boolean).at(-1) ?? path
