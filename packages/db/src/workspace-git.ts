import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { journaledNavigationChanges } from "./navigation-changes.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeWorkspaceGitService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "setWorkspaceGit"> => {
  const journaled = journaledNavigationChanges(context)
  return {
    setWorkspaceGit: (workspaceId, head, pullRequest) =>
      attempt("setWorkspaceGit", () =>
        journaled(() => {
          const keepsPullRequest = pullRequest === undefined ? 1 : 0
          const serialized = pullRequest == null ? null : JSON.stringify(pullRequest)
          context.sqlite.prepare(workspaceGitSql).run({
            id: canonicalUuid(workspaceId),
            branch: head.branch,
            detachedHead: head.detachedHead ?? null,
            keeps: keepsPullRequest,
            pullRequest: serialized
          })
        })
      )
  }
}

const workspaceGitSql = `update workspaces set
                   git_branch = @branch,
                   git_detached_head = @detachedHead,
                   git_pull_request = case when @keeps then git_pull_request else @pullRequest end,
                   git_known = 1
                 where id = @id
                   and (git_known = 0
                     or git_branch is not @branch
                     or git_detached_head is not @detachedHead
                     or (not @keeps and git_pull_request is not @pullRequest))`
