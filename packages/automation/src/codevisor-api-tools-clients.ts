import { ClientNavigationRequest } from "@codevisor/api"
import { apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export const codevisorClientApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "clients.list",
    "Discover connected native Codevisor windows on this server. Each clientId targets exactly one window; never guess which device to navigate when several are connected.",
    "GET",
    "/v1/clients"
  ),
  apiTool(
    "clients.context",
    "Read fresh UI context from a specific connected client: active state, selected workspace, tabs, panes, and chat ids on this server. The client must be running and responsive.",
    "GET",
    "/v1/clients/:clientId/context"
  ),
  apiTool(
    "clients.navigate",
    "Open a workspace and optionally select a tab, pane, or chat in one specific native client. Use ids from clients.context; newly created shared panes must synchronize to that client first. The workspace must have a chat available to anchor its native route. Returns the client's acknowledged context. This changes that client's selection, not shared pane content or layout on other devices.",
    "POST",
    "/v1/clients/:clientId/navigate",
    { body: ClientNavigationRequest }
  )
]
