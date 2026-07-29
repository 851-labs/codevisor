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

/// Scratch workspace folders — the empty directory a brand-new chat workspace
/// starts in before the user locks it to a project or worktree. They live
/// beside the per-project worktree directories under ~/codevisor; "workspaces"
/// can never collide with a project directory because those are keyed by UUID.
export const scratchWorkspacesRoot = (): string => join(worktreesRoot(), "workspaces")

export const scratchWorkspacePath = (name: string): string => join(scratchWorkspacesRoot(), name)

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
