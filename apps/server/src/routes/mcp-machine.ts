import { SetMachineMcpEnabledRequest } from "@codevisor/api"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  MCP_OVERLAYS_NAMESPACE,
  mcpOverlayDisableKey,
  readMcpOverlays
} from "../infra/mcp-fleet.js"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { refreshMcpReadiness } from "./sync-reconcilers.js"

/// Mirrors the native switch: off suppresses only this machine; on clears
/// that override and, if necessary, enables the shared definition as well.
export const routeMachineMcps = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const id = matchRoute(url.pathname, "/v1/mcps/:id/machine-state")
  if (id === undefined) return false
  const manager = services.mcp
  if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
  let server = (await manager.list()).find((candidate) => candidate.id === id)
  if (server === undefined) throw new HttpFailure(404, "MCP server not found")
  if (request.method === "PUT") {
    const { enabled } = await readSchema(request, SetMachineMcpEnabledRequest)
    // Re-enable before removing suppression. A failed update leaves the
    // existing per-machine disable intact.
    if (enabled && !server.enabled) server = await manager.update(id, { enabled: true })
    const entries = await run(services.db.getSyncEntries(MCP_OVERLAYS_NAMESPACE))
    const result = await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        {
          key: mcpOverlayDisableKey(config.id, server.name),
          value: enabled ? null : { enabled: false },
          ...(enabled ? { deleted: true } : {}),
          timestamp: nextSyncTimestamp(config.id, latestSyncTimestamp(entries), Date.now())
        }
      ])
    )
    await manager.setLocalSuppression((await readMcpOverlays(services.db, config.id)).disabledHere)
    await appendAndPublish(services.db, fanout, "sync.changed", MCP_OVERLAYS_NAMESPACE, {
      namespace: MCP_OVERLAYS_NAMESPACE,
      entries: result.changed
    })
    await refreshMcpReadiness(services, config, fanout)
    const updated = (await manager.list()).find((candidate) => candidate.id === id)
    if (updated === undefined)
      throw new HttpFailure(404, "MCP server was removed while changing availability")
    server = updated
  } else if (request.method !== "GET") {
    throw new HttpFailure(405, "Method not allowed")
  }
  const disabledHere = (await readMcpOverlays(services.db, config.id)).disabledHere.has(server.name)
  writeJson(response, 200, {
    machineId: config.id,
    server,
    disabledHere,
    enabled: server.enabled && !disabledHere
  })
  return true
}
