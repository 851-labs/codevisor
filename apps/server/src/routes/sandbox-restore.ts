import type { Workspace } from "@codevisor/api"

import { SANDBOX_RESTORE_LABEL } from "../infra/sandbox-watch.js"
import { swallowError } from "../server-context.js"
import type { RouteContext } from "./route-context.js"

export const restoreSandboxWhenUnarchived = (
  route: RouteContext,
  workspace: Workspace,
  wasArchived: boolean
): void => {
  if (!wasArchived || workspace.isArchived) return
  if (workspace.labels?.[SANDBOX_RESTORE_LABEL] === undefined) return

  void route.services.sandboxes?.sandboxes.restore(workspace.id).catch(swallowError)
}
