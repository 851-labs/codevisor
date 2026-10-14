import type { CodevisorServerServices } from "./server-context-types.js"
import { run } from "./server-http.js"

export const settleCleanup = async (operations: ReadonlyArray<Promise<unknown>>): Promise<void> => {
  const results = await Promise.allSettled(operations)
  const errors = results.flatMap((result) => (result.status === "rejected" ? [result.reason] : []))
  if (errors.length > 0) throw new AggregateError(errors, "Workspace process cleanup failed")
}

export const workspaceTerminalKeys = async (
  services: CodevisorServerServices,
  workspaceIds: ReadonlyArray<string>
): Promise<ReadonlyArray<string>> => {
  const ids = new Set(workspaceIds.map((id) => id.toLowerCase()))
  return (await run(services.db.listWorkspacePanes)).flatMap((pane) =>
    ids.has(pane.workspaceId.toLowerCase()) &&
    pane.paneType === "terminal" &&
    pane.resourceId !== undefined
      ? [pane.resourceId]
      : []
  )
}
