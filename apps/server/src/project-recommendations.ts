import { readFileSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, isAbsolute, resolve, sep } from "node:path"

import type { AgentSessionSummary, ProjectRecommendation } from "@codevisor/api"
import { worktreesRoot } from "@codevisor/db"

import { openFolderAccess, type FolderAccess, type ProtectedFolder } from "./protected-folders.js"

interface RecommendationAggregate {
  readonly path: string
  sessionCount: number
  lastActivity?: string
  lastActivityTime?: number
}

export interface ProjectRecommendationOptions {
  readonly limit?: number
  readonly managedWorktreesRoot?: string
  readonly temporaryDirectory?: string
  readonly access?: FolderAccess
}

export interface HeldProject {
  readonly folder: ProtectedFolder
  readonly project: ProjectRecommendation
}

export interface SessionFolderScan {
  readonly recommendations: ReadonlyArray<ProjectRecommendation>
  readonly held: ReadonlyArray<HeldProject>
}

export const recommendProjectsFromSessions = (
  sessions: ReadonlyArray<AgentSessionSummary>,
  options: ProjectRecommendationOptions = {}
): ReadonlyArray<ProjectRecommendation> => scanSessionFolders(sessions, options).recommendations

export const scanSessionFolders = (
  sessions: ReadonlyArray<AgentSessionSummary>,
  options: ProjectRecommendationOptions = {}
): SessionFolderScan => {
  const limit = Math.max(0, Math.min(options.limit ?? 12, 50))
  if (limit === 0) return { recommendations: [], held: [] }
  const roots: ScanRoots = {
    managed: resolve(options.managedWorktreesRoot ?? worktreesRoot()),
    temporary: resolve(options.temporaryDirectory ?? tmpdir()),
    access: options.access ?? openFolderAccess
  }
  const projects = new Map<string, RecommendationAggregate>()
  const held = new Map<string, RecommendationAggregate>()
  const heldFolders = new Map<string, ProtectedFolder>()

  for (const session of sessions) {
    const place = sessionPlace(session, roots)
    if (place === undefined) continue
    if (place.folder !== undefined) heldFolders.set(place.path, place.folder)
    recordRecommendation(place.folder === undefined ? projects : held, place.path, session)
  }

  return {
    recommendations: byRecentActivity(projects).slice(0, limit).map(recommendationDTO),
    held: byRecentActivity(held).map((entry) => ({
      folder: heldFolders.get(entry.path)!,
      project: recommendationDTO(entry)
    }))
  }
}

interface ScanRoots {
  readonly managed: string
  readonly temporary: string
  readonly access: FolderAccess
}

interface SessionPlace {
  readonly path: string
  readonly folder?: ProtectedFolder
}

const byRecentActivity = (
  entries: ReadonlyMap<string, RecommendationAggregate>
): ReadonlyArray<RecommendationAggregate> =>
  [...entries.values()].toSorted((left, right) => compareRecommendations(left, right))

const sessionPlace = (session: AgentSessionSummary, roots: ScanRoots): SessionPlace | undefined => {
  if (!isAbsolute(session.cwd)) return undefined
  const sessionPath = resolve(session.cwd)
  if (sessionPath === "/") return undefined
  if (roots.access(sessionPath).kind !== "open") return unreadPlace(sessionPath, roots)

  const linked = linkedWorktree(sessionPath, roots.access)
  const isManaged = isPathInside(sessionPath, roots.managed)
  if (linked.isLinked && linked.root === undefined) return undefined
  if (isManaged && linked.root === undefined) return undefined

  const path = linked.root ?? sessionPath
  if (roots.access(path).kind !== "open") return unreadPlace(path, roots)
  return isRecommendationRoot(path, roots.managed, roots.temporary) ? { path } : undefined
}

const unreadPlace = (path: string, roots: ScanRoots): SessionPlace | undefined => {
  const access = roots.access(path)
  if (access.kind !== "held") return undefined
  if (isPathInside(path, roots.managed) || isExcludedPath(path, roots.temporary)) return undefined

  return { path, folder: access.folder }
}

const isRecommendationRoot = (
  path: string,
  managedRoot: string,
  temporaryRoot: string
): boolean => {
  return !(
    path === "/" ||
    isPathInside(path, managedRoot) ||
    isExcludedPath(path, temporaryRoot) ||
    !isDirectory(path)
  )
}

const recordRecommendation = (
  grouped: Map<string, RecommendationAggregate>,
  path: string,
  session: AgentSessionSummary
): void => {
  const lastActivity = session.updatedAt
  const activityTime = lastActivity === undefined ? undefined : Date.parse(lastActivity)
  const validActivityTime =
    activityTime === undefined || Number.isNaN(activityTime) ? undefined : activityTime
  const existing = grouped.get(path)
  if (existing === undefined) {
    grouped.set(path, {
      path,
      sessionCount: 1,
      ...(validActivityTime === undefined || lastActivity === undefined
        ? {}
        : { lastActivity, lastActivityTime: validActivityTime })
    })
    return
  }
  updateRecommendation(existing, lastActivity, validActivityTime)
}

const updateRecommendation = (
  existing: RecommendationAggregate,
  lastActivity: string | undefined,
  validActivityTime: number | undefined
): void => {
  existing.sessionCount += 1
  if (
    validActivityTime !== undefined &&
    lastActivity !== undefined &&
    (existing.lastActivityTime === undefined || validActivityTime > existing.lastActivityTime)
  ) {
    existing.lastActivity = lastActivity
    existing.lastActivityTime = validActivityTime
  }
}

const compareRecommendations = (
  left: RecommendationAggregate,
  right: RecommendationAggregate
): number => {
  if (left.lastActivityTime !== right.lastActivityTime) {
    if (left.lastActivityTime === undefined) return 1
    if (right.lastActivityTime === undefined) return -1
    return right.lastActivityTime - left.lastActivityTime
  }
  if (left.sessionCount !== right.sessionCount) return right.sessionCount - left.sessionCount
  return basename(left.path).localeCompare(basename(right.path), undefined, {
    sensitivity: "base"
  })
}

const recommendationDTO = (entry: RecommendationAggregate): ProjectRecommendation => {
  return entry.lastActivity === undefined
    ? {
        path: entry.path,
        name: basename(entry.path),
        sessionCount: entry.sessionCount
      }
    : {
        path: entry.path,
        name: basename(entry.path),
        sessionCount: entry.sessionCount,
        lastActivity: entry.lastActivity
      }
}

const isDirectory = (path: string): boolean => {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

export const isPathInside = (path: string, root: string): boolean =>
  path === root || path.startsWith(`${root}${sep}`)

const isExcludedPath = (path: string, temporaryRoot: string): boolean => {
  if (path.split(sep).includes(".codevisor")) return true
  if (
    [temporaryRoot, "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"].some((root) =>
      isPathInside(path, resolve(root))
    )
  ) {
    return true
  }
  const components = path.split(sep).filter((component) => component.length > 0)
  const foldersIndex = components.findIndex(
    (component, index) => component === "folders" && components[index - 1] === "var"
  )
  return foldersIndex >= 0 && components[foldersIndex + 3] === "T"
}

const linkedWorktree = (
  checkout: string,
  access: FolderAccess
): { readonly isLinked: boolean; readonly root?: string } => {
  const dotGit = resolve(checkout, ".git")
  let info: ReturnType<typeof statSync>
  try {
    info = statSync(dotGit)
  } catch {
    return { isLinked: false }
  }
  if (info.isDirectory()) return { isLinked: false }

  try {
    const gitDirValue = metadataPath(readFileSync(dotGit, "utf8"), "gitdir")
    if (gitDirValue === undefined) return { isLinked: true }
    const gitDir = resolve(checkout, gitDirValue)
    if (access(gitDir).kind !== "open") return unreadWorktreeRoot(gitDir)
    const commonDirValue = readFileSync(resolve(gitDir, "commondir"), "utf8").trim()
    if (commonDirValue.length === 0) return { isLinked: true }
    const commonDir = resolve(gitDir, commonDirValue)
    if (basename(commonDir) !== ".git") return { isLinked: true }
    const root = dirname(commonDir)
    return isDirectory(root) ? { isLinked: true, root } : { isLinked: true }
  } catch {
    return { isLinked: true }
  }
}

const worktreeGitDir = /^(.+)\/\.git\/worktrees\/[^/]+$/u

const unreadWorktreeRoot = (
  gitDir: string
): { readonly isLinked: true; readonly root?: string } => {
  const root = worktreeGitDir.exec(gitDir)?.[1]
  return root === undefined ? { isLinked: true } : { isLinked: true, root }
}

const metadataPath = (contents: string, key: string): string | undefined => {
  const prefix = `${key}:`
  const line = contents.split(/\r?\n/u)[0]!
  if (!line.startsWith(prefix)) return undefined
  const value = line.slice(prefix.length).trim()
  return value.length === 0 ? undefined : value
}
