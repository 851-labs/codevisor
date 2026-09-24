import { randomUUID } from "node:crypto"

import type { CreateProjectRequest, Project, ProjectLocation } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { attempt } from "./errors.js"
import { detectGitLocation } from "./project-location-state.js"
import { projectFromRow } from "./row-mappers.js"
import type { ProjectRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeProjectsService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createProject"
  | "listProjects"
  | "updateProject"
  | "deleteProject"
  | "setProjectRepoUrl"
  | "setProjectLocationGitState"
> => {
  const { sqlite, config, locationRowsFor, getProject } = context

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
                id, name, origin, created_at, repo_url,
                worktree_base_remote, worktree_base_branch
              ) values (?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
              projectId,
              request.name ?? basename(request.folderPath),
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
        isGitRepository: detectGitLocation(request.folderPath),
        createdAt
      }
      const project: Project = {
        id: projectId,
        name: request.name ?? basename(request.folderPath),
        origin: request.origin ?? "codevisor",
        createdAt,
        locations: [location],
        ...(request.repoUrl === undefined ? {} : { repoUrl: request.repoUrl })
      }
      const transaction = sqlite.transaction(() => {
        sqlite
          .prepare(
            `insert into projects (
              id, name, origin, created_at, repo_url,
              worktree_base_remote, worktree_base_branch
            ) values (?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            project.id,
            project.name,
            project.origin,
            project.createdAt,
            project.repoUrl ?? null,
            null,
            null
          )
        sqlite
          .prepare(
            `insert into project_locations (
              id, project_id, server_id, folder_path, created_at, is_git_repository
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(
            location.id,
            location.projectId,
            location.serverId,
            location.folderPath,
            location.createdAt,
            Number(location.isGitRepository)
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
        const worktreeBase =
          request.worktreeBase === undefined
            ? current.worktreeBase
            : (request.worktreeBase ?? undefined)
        sqlite
          .prepare(
            `update projects set name = ?,
              worktree_base_remote = ?, worktree_base_branch = ?
             where id = ? collate nocase`
          )
          .run(
            request.name ?? current.name,
            worktreeBase?.remote ?? null,
            worktreeBase?.branch ?? null,
            id
          )
        return getProject(id)
      }),
    setProjectLocationGitState: (id, isGitRepository) =>
      attempt("setProjectLocationGitState", () => {
        sqlite
          .prepare(
            "update project_locations set is_git_repository = ? where id = ? and is_git_repository is not ?"
          )
          .run(Number(isGitRepository), id, Number(isGitRepository))
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
