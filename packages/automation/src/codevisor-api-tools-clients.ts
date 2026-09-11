import {
  ClientNavigationRequest,
  ClientPageRequest,
  ClientLayoutRequest,
  ClientWindowRequest
} from "@codevisor/api"
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
    "Read fresh UI context from a specific connected client: current page and presentation, supported actions and settings sections, window geometry, selected workspace, tabs, split branches with fractions and child leaf ids, panes, and chat ids on this server. Older clients may omit newer fields. The client must be running and responsive.",
    "GET",
    "/v1/clients/:clientId/context"
  ),
  apiTool(
    "clients.navigate",
    "Open a workspace and optionally select a tab, pane, or chat in one specific native client. Use ids from clients.context; newly created shared panes must synchronize to that client first. The workspace must have a chat available to anchor its native route. Returns the client's acknowledged context. This changes that client's selection, not shared pane content or layout on other devices.",
    "POST",
    "/v1/clients/:clientId/navigate",
    { body: ClientNavigationRequest }
  ),
  apiTool(
    "clients.open_page",
    "Navigate a specific native client to home, a new-chat draft (optionally for projectId on this server), or a settings section; dismiss returns from a settings presentation. Read clients.context capabilities for supported sections. macOS Settings is an app-wide window; home/new_chat affect the addressed main window. Commands preserve unsent drafts and reject blocking presentations. Returns acknowledged context.",
    "POST",
    "/v1/clients/:clientId/page",
    { body: ClientPageRequest, wrappedBody: true }
  ),
  apiTool(
    "clients.layout",
    "Change one client's device-local workspace layout. Actions: new_tab, split a leaf with a New Tab pane, move a leaf beside another (including across tabs), detach a leaf into its own tab, resize a split, reorder_tabs, or rename_tab (empty title resets). Read supported actions and ids from clients.context. resize requires branchPath, positive fractions summing to 1, and expectedChildren matching that split's current child leaf ids to reject stale topology. reorder_tabs requires every current tab id exactly once. Creating a New Tab also publishes its pane to the shared workspace; existing pane moves and sizes are local. Pane closing uses workspaces.pane_close. Returns acknowledged context.",
    "POST",
    "/v1/clients/:clientId/layout",
    { body: ClientLayoutRequest }
  ),
  apiTool(
    "clients.window",
    "Control the specifically addressed native window: focus, minimize, restore, set fullscreen enabled, frame, or sidebar visible. Discover supported actions in clients.context (iOS window geometry is system-managed). frame uses macOS screen coordinates in points, origin at the bottom left; dimensions include window chrome and must fit a visible screen. Native minimum sizes apply. Returns the actual acknowledged window state.",
    "POST",
    "/v1/clients/:clientId/window",
    { body: ClientWindowRequest, wrappedBody: true }
  )
]
