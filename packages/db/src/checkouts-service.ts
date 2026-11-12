import type { Checkout, GitHead, GitPullRequest } from "@codevisor/api"
import type { Effect } from "effect"

import { listCheckoutRows } from "./checkouts.js"
import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { checkoutFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface CheckoutsService {
  readonly listCheckouts: Effect.Effect<ReadonlyArray<Checkout>, DatabaseError>
  readonly findWorkspaceShowingSession: (
    sessionId: string
  ) => Effect.Effect<string | undefined, DatabaseError>
}

const parentChainLimit = 8

export const makeCheckoutsService = (context: ServiceContext): CheckoutsService => {
  const { sqlite, config } = context
  return {
    listCheckouts: attempt("listCheckouts", () => listCheckoutRows(sqlite).map(checkoutFromRow)),
    findWorkspaceShowingSession: (sessionId) =>
      attempt("findWorkspaceShowingSession", () =>
        workspaceShowingSession(sqlite, config.serverId, canonicalUuid(sessionId))
      )
  }
}

export const writeCheckoutGit = (
  sqlite: ServiceContext["sqlite"],
  checkoutId: string,
  head: GitHead,
  pullRequest: GitPullRequest | null | undefined
): void => {
  sqlite.prepare(checkoutGitSql).run({
    id: checkoutId,
    branch: head.branch,
    detachedHead: head.detachedHead ?? null,
    keeps: pullRequest === undefined ? 1 : 0,
    pullRequest: pullRequest == null ? null : JSON.stringify(pullRequest)
  })
}

const workspaceShowingSession = (
  sqlite: ServiceContext["sqlite"],
  serverId: string,
  sessionId: string
): string | undefined => {
  let current: string | undefined = sessionId
  for (let depth = 0; current !== undefined && depth < parentChainLimit; depth += 1) {
    const shown = workspaceWithPaneFor(sqlite, current)
    if (shown !== undefined) return shown
    current = localParentOf(sqlite, serverId, current)
  }
  return homeWorkspaceOf(sqlite, sessionId)
}

const workspaceWithPaneFor = (sqlite: ServiceContext["sqlite"], sessionId: string) =>
  workspaceIdRows.maybe(sqlite.prepare(showingSql.paneWorkspace).get(sessionId))?.workspace_id

const localParentOf = (sqlite: ServiceContext["sqlite"], serverId: string, sessionId: string) =>
  parentRows.maybe(sqlite.prepare(showingSql.localParent).get(sessionId, serverId))?.parent_id

const homeWorkspaceOf = (sqlite: ServiceContext["sqlite"], sessionId: string) =>
  workspaceIdRows.maybe(sqlite.prepare(showingSql.homeWorkspace).get(sessionId))?.workspace_id

const workspaceIdRows = rowReader({ workspace_id: text })

const parentRows = rowReader({ parent_id: text })

const showingSql = {
  paneWorkspace: `select workspace_panes.workspace_id from workspace_panes
      join workspaces on workspaces.id = workspace_panes.workspace_id
      where workspace_panes.resource_kind = 'session' and workspace_panes.resource_id = ?
      order by workspaces.is_archived, workspace_panes.created_at, workspace_panes.id limit 1`,
  localParent: `select created_by_agent_id as parent_id from sessions
      where id = ? and created_by_agent_id is not null
        and (created_by_agent_machine_id is null or created_by_agent_machine_id = ?)`,
  homeWorkspace: "select workspace_id from sessions where id = ? and workspace_id is not null"
}

const checkoutGitSql = `update checkouts set
                   git_branch = @branch,
                   git_detached_head = @detachedHead,
                   git_pull_request = case when @keeps then git_pull_request else @pullRequest end,
                   git_known = 1,
                   updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                 where id = @id
                   and (git_known = 0
                     or git_branch is not @branch
                     or git_detached_head is not @detachedHead
                     or (not @keeps and git_pull_request is not @pullRequest))`
