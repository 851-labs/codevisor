import { writeCheckoutGit } from "./checkouts-service.js"
import { workspaceDefaultCheckoutId } from "./checkouts.js"
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
    setWorkspaceGit: (rawWorkspaceId, head, pullRequest) =>
      attempt("setWorkspaceGit", () =>
        journaled(() => {
          const workspaceId = canonicalUuid(rawWorkspaceId)
          const checkoutId = workspaceDefaultCheckoutId(context.sqlite, workspaceId)
          if (checkoutId !== null) writeCheckoutGit(context.sqlite, checkoutId, head, pullRequest)
        })
      )
  }
}
