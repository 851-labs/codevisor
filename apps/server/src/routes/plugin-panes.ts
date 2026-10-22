import type { EventEnvelope, PluginSummary, WorkspacePane } from "@codevisor/api"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import type { RouteContext } from "./route-context.js"

export const withOpenPaneCount = async (
  services: CodevisorServerServices,
  summary: PluginSummary
): Promise<PluginSummary> => ({
  ...summary,
  openPaneCount: (await listPluginPanes(services, summary.id)).length
})

export const deletePluginPanes = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  pluginId: string
): Promise<void> => {
  for (const pane of await listPluginPanes(services, pluginId)) {
    await run(services.db.deleteWorkspacePane(pane.workspaceId, pane.id))

    await appendAndPublish(services.db, fanout, "workspace.pane.deleted", pane.id, {
      id: pane.id,
      workspaceId: pane.workspaceId
    })
  }
}

export const publishPluginUpdated = (
  { services, fanout }: RouteContext,
  plugin: PluginSummary
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "plugin.updated", plugin.id, plugin)

const listPluginPanes = async (
  services: CodevisorServerServices,
  pluginId: string
): Promise<ReadonlyArray<WorkspacePane>> => {
  const providerId = `plugin:${pluginId}`
  return (await run(services.db.listWorkspacePanes)).filter(
    (pane) => pane.providerId === providerId
  )
}
