import type { AgentSessionSummary, ProjectRecommendation } from "@codevisor/api"
import { readFileSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, isAbsolute, resolve, sep } from "node:path"
import { worktreesRoot } from "@codevisor/db"

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
}

/// Derives useful project roots from harness-owned sessions on this machine.
/// Filesystem and Git metadata checks deliberately run beside those sessions;
/// a remote app cannot safely validate these paths on its own device.
export const recommendProjectsFromSessions = (
  sessions: ReadonlyArray<AgentSessionSummary>,
  options: ProjectRecommendationOptions = {}
): ReadonlyArray<ProjectRecommendation> => {
  const limit = Math.max(0, Math.min(options.limit ?? 12, 50))
  if (limit === 0) return []
  const managedRoot = resolve(options.managedWorktreesRoot ?? worktreesRoot())
  const temporaryRoot = resolve(options.temporaryDirectory ?? tmpdir())
  const grouped = new Map<string, RecommendationAggregate>()

  for (const session of sessions) {
    if (!isAbsolute(session.cwd)) continue
    const sessionPath = resolve(session.cwd)
    if (sessionPath === "/") continue

    const linked = linkedWorktree(sessionPath)
    const isManaged = isPathInside(sessionPath, managedRoot)
    // A linked checkout without a surviving primary checkout is temporary;
    // never suggest the short-lived worktree itself.
    if (linked.isLinked && linked.root === undefined) continue
    // Codevisor-managed worktrees are likewise suggestions only when their
    // Git metadata leads back to a real checkout outside the managed root.
    if (isManaged && linked.root === undefined) continue

    const path = linked.root ?? sessionPath
    if (
      path === "/" ||
      isPathInside(path, managedRoot) ||
      isExcludedPath(path, temporaryRoot) ||
      !isDirectory(path)
    ) {
      continue
    }

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
      continue
    }
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

  return [...grouped.values()]
    .toSorted((left, right) => {
      if (left.lastActivityTime !== right.lastActivityTime) {
        if (left.lastActivityTime === undefined) return 1
        if (right.lastActivityTime === undefined) return -1
        return right.lastActivityTime - left.lastActivityTime
      }
      if (left.sessionCount !== right.sessionCount) return right.sessionCount - left.sessionCount
      return basename(left.path).localeCompare(basename(right.path), undefined, {
        sensitivity: "base"
      })
    })
    .slice(0, limit)
    .map((entry) =>
      entry.lastActivity === undefined
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
    )
}

const isDirectory = (path: string): boolean => {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

const isPathInside = (path: string, root: string): boolean =>
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
  checkout: string
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

const metadataPath = (contents: string, key: string): string | undefined => {
  const prefix = `${key}:`
  const line = contents.split(/\r?\n/u)[0]!
  if (!line.startsWith(prefix)) return undefined
  const value = line.slice(prefix.length).trim()
  return value.length === 0 ? undefined : value
}
