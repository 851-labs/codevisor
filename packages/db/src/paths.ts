import { homedir } from "node:os"
import { join } from "node:path"

/// The worktree location is fixed at ~/herdman by design (sessions derive
/// their cwd from it on any machine). The env override exists for tests only.
export const worktreesRoot = (): string =>
  process.env["HERDMAN_WORKTREES_ROOT"] ?? join(homedir(), "herdman")

export const worktreePath = (projectId: string, worktreeName: string): string =>
  join(worktreesRoot(), projectId, worktreeName)

export const resolveSessionCwd = (
  folderPath: string | undefined,
  projectId: string,
  worktreeName: string | undefined
): string | undefined =>
  worktreeName === undefined ? folderPath : worktreePath(projectId, worktreeName)
