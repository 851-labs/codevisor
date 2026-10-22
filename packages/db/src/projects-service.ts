import { randomUUID } from "node:crypto"

import type { CreateProjectRequest, Project, ProjectLocation } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { idRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { detectGitLocation } from "./project-location-state.js"
import { projectFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { projectRows } from "./rows.js"
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
  const { sqlite, config, getProject } = context

  const createProject = Effect.fn("CodevisorDatabase.createProject")(function* (
    request: CreateProjectRequest
  ) {
    return yield* attempt("createProject", () => {
      const now = isoTimestamp()
      const projectId = (request.id ?? randomUUID()).toLowerCase()
      const createdAt = request.createdAt ?? now

      const existingId = projectIdMatching(sqlite, projectId)
      if (existingId !== undefined) return getProject(existingId)

      const claimedId = folderOwnerId(sqlite, config.serverId, request.folderPath)
      if (claimedId !== undefined) {
        return adoptClaimedFolder(context, request, projectId, createdAt, claimedId)
      }

      return insertProject(context, request, projectId, createdAt)
    })
  })

  return {
    createProject,
    listProjects: attempt("listProjects", () => projectsNewestFirst(context)),
    updateProject: (id, request) =>
      attempt("updateProject", () => {
        const current = getProject(id)
        const worktreeBase =
          request.worktreeBase === undefined
            ? current.worktreeBase
            : (request.worktreeBase ?? undefined)
        const defaultRunLocation =
          request.defaultRunLocation === undefined
            ? current.defaultRunLocation
            : (request.defaultRunLocation ?? undefined)
        sqlite
          .prepare(projectSql.update)
          .run(
            request.name ?? current.name,
            worktreeBase?.remote ?? null,
            worktreeBase?.branch ?? null,
            defaultRunLocation ?? null,
            id
          )
        return getProject(id)
      }),
    setProjectLocationGitState: (id, isGitRepository) =>
      attempt("setProjectLocationGitState", () => {
        sqlite
          .prepare(projectLocationSql.setGitState)
          .run(Number(isGitRepository), id, Number(isGitRepository))
      }),
    setProjectRepoUrl: (id, repoUrl) =>
      attempt("setProjectRepoUrl", () => {
        const result = sqlite.prepare(projectSql.setRepoUrl).run(repoUrl, id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
        return getProject(id)
      }),
    deleteProject: (id) =>
      attempt("deleteProject", () => {
        const result = sqlite.prepare(projectSql.delete).run(id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
      })
  }
}

const projectsNewestFirst = (context: ServiceContext): ReadonlyArray<Project> =>
  projectRows
    .all(context.sqlite.prepare(projectSql.list).all())
    .map((row) => projectFromRow(row, context.locationRowsFor(row.id)))

const adoptClaimedFolder = (
  context: ServiceContext,
  request: CreateProjectRequest,
  projectId: string,
  createdAt: string,
  claimedId: string
): Project => {
  const { sqlite, getProject } = context

  if (keepsClaimedProject(request, projectId, claimedId)) return getProject(claimedId)

  const claimedProject = getProject(claimedId)
  const merge = sqlite.transaction(() => {
    insertReplacementProject(sqlite, request, projectId, createdAt, claimedProject)
    rehomeProjectChildren(sqlite, projectId, claimedId)
  })
  merge()
  return getProject(projectId)
}

const keepsClaimedProject = (
  request: CreateProjectRequest,
  projectId: string,
  claimedId: string
): boolean => request.id === undefined || claimedId.toLowerCase() === projectId

const insertProject = (
  context: ServiceContext,
  request: CreateProjectRequest,
  projectId: string,
  createdAt: string
): Project => {
  const { sqlite, config } = context

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
    insertNewProjectRow(sqlite, project)
    insertProjectLocationRow(sqlite, location)
  })
  transaction()
  return project
}

const insertReplacementProject = (
  sqlite: ServiceContext["sqlite"],
  request: CreateProjectRequest,
  projectId: string,
  createdAt: string,
  claimedProject: Project
): void => {
  sqlite
    .prepare(projectSql.insertReplacement)
    .run(
      projectId,
      request.name ?? basename(request.folderPath),
      request.origin ?? "codevisor",
      createdAt,
      request.repoUrl ?? null,
      claimedProject.worktreeBase?.remote ?? null,
      claimedProject.worktreeBase?.branch ?? null,
      claimedProject.defaultRunLocation ?? null
    )
}

const rehomeProjectChildren = (
  sqlite: ServiceContext["sqlite"],
  projectId: string,
  claimedId: string
): void => {
  for (const table of projectChildTables) {
    sqlite.prepare(rehomeChildrenSql(table)).run(projectId, claimedId)
  }
  sqlite.prepare(projectSql.deleteClaimed).run(claimedId)
}

const insertNewProjectRow = (sqlite: ServiceContext["sqlite"], project: Project): void => {
  sqlite
    .prepare(projectSql.insertNew)
    .run(
      project.id,
      project.name,
      project.origin,
      project.createdAt,
      project.repoUrl ?? null,
      null,
      null
    )
}

const insertProjectLocationRow = (
  sqlite: ServiceContext["sqlite"],
  location: ProjectLocation
): void => {
  sqlite
    .prepare(projectLocationSql.insert)
    .run(
      location.id,
      location.projectId,
      location.serverId,
      location.folderPath,
      location.createdAt,
      Number(location.isGitRepository)
    )
}

const basename = (path: string): string => path.split("/").findLast(Boolean) ?? path

const projectIdMatching = (
  sqlite: ServiceContext["sqlite"],
  projectId: string
): string | undefined => idRows.maybe(sqlite.prepare(projectSql.idMatching).get(projectId))?.id

const folderOwnerId = (
  sqlite: ServiceContext["sqlite"],
  serverId: string,
  folderPath: string
): string | undefined =>
  projectIdRows.maybe(sqlite.prepare(projectLocationSql.folderOwner).get(serverId, folderPath))
    ?.project_id

const projectChildTables = ["project_locations", "sessions", "worktrees"]

const projectIdRows = rowReader({ project_id: text })

const projectSql = {
  idMatching: "select id from projects where id = ? collate nocase",
  list: "select * from projects order by created_at desc",
  update: `update projects set name = ?,
              worktree_base_remote = ?, worktree_base_branch = ?,
              default_run_location = ?
             where id = ? collate nocase`,
  setRepoUrl: "update projects set repo_url = ? where id = ? collate nocase",
  delete: "delete from projects where id = ? collate nocase",
  insertReplacement: `insert into projects (
                id, name, origin, created_at, repo_url,
                worktree_base_remote, worktree_base_branch, default_run_location
              ) values (?, ?, ?, ?, ?, ?, ?, ?)`,
  deleteClaimed: "delete from projects where id = ?",
  insertNew: `insert into projects (
              id, name, origin, created_at, repo_url,
              worktree_base_remote, worktree_base_branch
            ) values (?, ?, ?, ?, ?, ?, ?)`
}

const projectLocationSql = {
  folderOwner: "select project_id from project_locations where server_id = ? and folder_path = ?",
  setGitState:
    "update project_locations set is_git_repository = ? where id = ? and is_git_repository is not ?",
  insert: `insert into project_locations (
              id, project_id, server_id, folder_path, created_at, is_git_repository
            ) values (?, ?, ?, ?, ?, ?)`
}

const rehomeChildrenSql = (table: string): string =>
  `update ${table} set project_id = ? where project_id = ?`
