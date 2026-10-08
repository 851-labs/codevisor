import { PutNavigationRecordsRequest } from "@codevisor/api"

import { apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

/// Account-wide sidebar organization: folders, the grouping mode, and
/// project order. Workspace filing, ownership and tab groups live on the
/// workspace itself (workspaces.update).
export const codevisorNavigationApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "navigation.records_list",
    "List the sidebar's replicated records: folders (tombstoned ones carry deleted: true) and settings such as sidebar.grouping (none or project) and project.order.<projectId> (a position key).",
    "GET",
    "/v1/navigation/records"
  ),
  apiTool(
    "navigation.records_put",
    "Create, rename, reorder, collapse, or delete sidebar folders, or change navigation settings, on every client. Each record needs a revision: a clock stamp `<13-digit epoch ms>-<6-digit counter>-<writer>` (for example `${String(Date.now()).padStart(13, '0')}-000000-agent`); a write only lands when its revision is newer than the stored one, and clients copy it to the user's other machines. Delete a folder by writing it with deleted: true. File a workspace into a folder with workspaces.update folderId. sidebar.grouping is none (folders and loose agents, in sidebar order) or project.",
    "PUT",
    "/v1/navigation/records",
    { body: PutNavigationRecordsRequest }
  )
]
