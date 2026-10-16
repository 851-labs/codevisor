import { homedir } from "node:os"
import { dirname, join } from "node:path"

export const worktreesRoot = (): string =>
  process.env["CODEVISOR_WORKTREES_ROOT"] ??
  process.env["HERDMAN_WORKTREES_ROOT"] ??
  join(homedir(), "codevisor")

export const worktreePath = (projectId: string, worktreeName: string): string =>
  join(worktreesRoot(), projectId, worktreeName)

export const scratchWorkspacesRoot = (): string => join(worktreesRoot(), "workspaces")

export const scratchWorkspacePath = (name: string): string => join(scratchWorkspacesRoot(), name)

export const botsRoot = (): string => join(worktreesRoot(), "bots")

export const botPath = (slug: string): string => join(botsRoot(), slug)

export const isScratchFolder = (folderPath: string): boolean =>
  dirname(folderPath) === scratchWorkspacesRoot()

export const isBotFolder = (folderPath: string): boolean => dirname(folderPath) === botsRoot()

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
