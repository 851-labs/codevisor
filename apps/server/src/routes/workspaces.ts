import {
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  applyCascadedSessionEffects,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

/// Pane workspaces are client-authored identity records, so writes are
/// idempotent PUTs keyed by the client's workspace id. Creates and updates
/// share one `workspace.updated` event to keep client mirroring simple.
export const routeWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/workspaces") {
    writeJson(response, 200, await run(services.db.listWorkspaces))
    return true
  }

  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspaceRequestSchema)
    // UUID comparison is case-insensitive: the path id is canonicalized to
    // lowercase while Swift clients send uppercase body ids.
    if (payload.id !== undefined && payload.id.toLowerCase() !== workspaceId.toLowerCase()) {
      throw new HttpFailure(
        400,
        `Workspace id in the body (${payload.id}) does not match the path (${workspaceId})`
      )
    }
    const sessionsBefore = await run(services.db.listSessions)
    const workspace = await run(services.db.upsertWorkspace({ ...payload, id: workspaceId }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    // A PUT can flip the archive bit exactly like the PATCH below, so it owes
    // the same teardown/restore.
    await applyCascadedSessionEffects(services, fanout, config, sessionsBefore)
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspaceRequestSchema)
    const sessionsBefore =
      payload.isArchived === undefined ? [] : await run(services.db.listSessions)
    const workspace = await run(services.db.updateWorkspace(workspaceId, payload))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    if (payload.isArchived !== undefined) {
      await applyCascadedSessionEffects(services, fanout, config, sessionsBefore)
    }
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    writeJson(response, 204, undefined)
    return true
  }

  return false
}
