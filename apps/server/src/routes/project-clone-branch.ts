import type { ProjectWorktreeBase } from "@codevisor/api"
import {
  checkoutNewBranch,
  listCodevisorWorktreeBranchNames,
  listRemoteCodevisorBranchNames,
  worktreeStartPoint
} from "@codevisor/worktrees"

import type { CodevisorServerConfig } from "../server-context.js"
import { nextWorktreeName, worktreeBranchName } from "./project-worktree-create.js"

export interface NewCloneBranch {
  readonly worktreeBase: ProjectWorktreeBase | undefined
  readonly worktreeNameStyle: CodevisorServerConfig["worktreeNameStyle"]
  readonly environment: NodeJS.ProcessEnv
}

export const startCloneOnNewBranch = async (
  folderPath: string,
  { worktreeBase, worktreeNameStyle, environment }: NewCloneBranch
): Promise<void> => {
  const taken = new Set([
    ...(await listCodevisorWorktreeBranchNames(folderPath, environment)),
    ...(await listRemoteCodevisorBranchNames(folderPath, environment))
  ])
  const startPoint = await worktreeStartPoint(folderPath, worktreeBase, environment)
  const branch = worktreeBranchName(nextWorktreeName({ worktreeNameStyle }, undefined, taken))
  await checkoutNewBranch(folderPath, branch, startPoint, environment)
}
