import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"

export const worktreesRoot = (): string =>
  process.env["CODEVISOR_WORKTREES_ROOT"] ??
  process.env["HERDMAN_WORKTREES_ROOT"] ??
  join(homedir(), "codevisor")

export const projectWorktreesRoot = (): string => join(worktreesRoot(), "worktrees.noindex")

export const legacyWorktreePath = (projectId: string, worktreeName: string): string =>
  join(worktreesRoot(), projectId, worktreeName)

export const unindexedWorktreePath = (projectId: string, worktreeName: string): string =>
  join(projectWorktreesRoot(), projectId, worktreeName)

export const worktreePath = (projectId: string, worktreeName: string): string => {
  const legacy = legacyWorktreePath(projectId, worktreeName)
  return existsSync(legacy) ? legacy : unindexedWorktreePath(projectId, worktreeName)
}

export const worktreeNameAt = (projectId: string, path: string): string | undefined => {
  const name = basename(path)
  return path === legacyWorktreePath(projectId, name) ||
    path === unindexedWorktreePath(projectId, name)
    ? name
    : undefined
}

export const worktreePathBeside = (projectId: string, previous: string, name: string): string =>
  previous === legacyWorktreePath(projectId, basename(previous))
    ? legacyWorktreePath(projectId, name)
    : unindexedWorktreePath(projectId, name)

export const scratchWorkspacesRoot = (): string => join(worktreesRoot(), "workspaces")

export const scratchWorkspacePath = (name: string): string => join(scratchWorkspacesRoot(), name)

export const botsRoot = (): string => join(worktreesRoot(), "bots.noindex")

export const legacyBotsRoot = (): string => join(worktreesRoot(), "bots")

export const botPath = (slug: string): string => {
  const legacy = join(legacyBotsRoot(), slug)
  return existsSync(legacy) ? legacy : join(botsRoot(), slug)
}

export const worktreeTrashRoot = (): string => join(worktreesRoot(), ".trash.noindex")

export const legacyWorktreeTrashRoot = (): string => join(worktreesRoot(), ".trash")

export const isScratchFolder = (folderPath: string): boolean =>
  dirname(folderPath) === scratchWorkspacesRoot()

export const isBotFolder = (folderPath: string): boolean =>
  dirname(folderPath) === botsRoot() || dirname(folderPath) === legacyBotsRoot()

export const isManagedFolder = (folderPath: string): boolean =>
  isScratchFolder(folderPath) || isBotFolder(folderPath)

export const managedRepoPath = (name: string): string =>
  join(process.env["CODEVISOR_REPOS_ROOT"] ?? join(homedir(), ".codevisor", "repos"), name)

export const resolveSessionCwd = (
  folderPath: string | undefined,
  projectId: string,
  worktreeName: string | undefined
): string | undefined =>
  worktreeName === undefined ? folderPath : worktreePath(projectId, worktreeName)
