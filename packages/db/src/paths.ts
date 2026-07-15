import { homedir } from "node:os"
import { join } from "node:path"

/// The worktree location is fixed at ~/codevisor by design (sessions derive
/// their cwd from it on any machine). The env override exists for tests only.
export const worktreesRoot = (): string =>
  process.env["CODEVISOR_WORKTREES_ROOT"] ??
  process.env["HERDMAN_WORKTREES_ROOT"] ??
  join(homedir(), "codevisor")

export const worktreePath = (projectId: string, worktreeName: string): string =>
  join(worktreesRoot(), projectId, worktreeName)

/// Managed git clones (projects added from a remote URL) live in the canonical
/// ~/.codevisor layout, identically on every machine, so a project can be
/// re-materialized anywhere by cloning the same remote. The env override
/// exists for tests only.
export const managedReposRoot = (): string =>
  process.env["CODEVISOR_REPOS_ROOT"] ?? join(homedir(), ".codevisor", "repos")

export const managedRepoPath = (name: string): string => join(managedReposRoot(), name)

export const resolveSessionCwd = (
  folderPath: string | undefined,
  projectId: string,
  worktreeName: string | undefined
): string | undefined =>
  worktreeName === undefined ? folderPath : worktreePath(projectId, worktreeName)
