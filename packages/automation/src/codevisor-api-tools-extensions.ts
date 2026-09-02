import {
  CreateMcpServerRequest,
  CreateSkillRequest,
  DetectMcpAuthRequest,
  DiscoverRemoteSkillsRequest,
  ImportNativeMcpsRequest,
  ImportRemoteSkillRequest,
  ImportSkillRequest,
  MakeSkillGlobalRequest,
  RemoveNativeMcpRequest,
  SetNativeMcpEnabledRequest,
  SetSkillInstalledRequest,
  SyncSkillsRequest,
  UpdateMcpServerRequest
} from "@codevisor/api"
import { enabledBody, apiTool, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

/// MCP server, native MCP, and skill tools.
export const codevisorExtensionApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool("mcps.list", "List MCP servers managed by Codevisor.", "GET", "/v1/mcps"),
  apiTool("mcps.create", "Add an MCP server to Codevisor.", "POST", "/v1/mcps", {
    body: CreateMcpServerRequest
  }),
  apiTool(
    "mcps.detect_auth",
    "Probe an HTTP MCP server's authentication requirements.",
    "POST",
    "/v1/mcps/detect-auth",
    {
      body: DetectMcpAuthRequest
    }
  ),
  apiTool(
    "mcps.tools",
    "List tools exposed by one managed MCP server.",
    "GET",
    "/v1/mcps/:id/tools"
  ),
  apiTool("mcps.update", "Update or enable a managed MCP server.", "PATCH", "/v1/mcps/:id", {
    body: UpdateMcpServerRequest
  }),
  apiTool("mcps.delete", "Remove a managed MCP server.", "DELETE", "/v1/mcps/:id"),
  apiTool(
    "mcps.connect",
    "Connect and refresh one managed MCP server.",
    "POST",
    "/v1/mcps/:id/connect"
  ),
  apiTool(
    "mcps.oauth_start",
    "Start OAuth authorization for a managed MCP server.",
    "POST",
    "/v1/mcps/:id/oauth-start"
  ),
  apiTool(
    "mcps.oauth_disconnect",
    "Disconnect OAuth from a managed MCP server.",
    "POST",
    "/v1/mcps/:id/oauth-disconnect"
  ),
  apiTool(
    "mcps.project_enable",
    "Override an MCP server's enabled state for a project.",
    "PATCH",
    "/v1/projects/:id/mcps/:mcpId",
    {
      body: enabledBody
    }
  ),
  apiTool(
    "mcps.session_enable",
    "Override an MCP server's enabled state for a session.",
    "PATCH",
    "/v1/sessions/:id/mcps/:mcpId",
    {
      body: enabledBody
    }
  ),
  apiTool(
    "native_mcps.scan",
    "Scan MCP servers configured directly in agent harnesses.",
    "GET",
    "/v1/native-mcps"
  ),
  apiTool(
    "native_mcps.import",
    "Import native harness MCPs into Codevisor management.",
    "POST",
    "/v1/native-mcps/import",
    {
      body: ImportNativeMcpsRequest
    }
  ),
  apiTool(
    "native_mcps.remove",
    "Remove and park an MCP entry from a harness config.",
    "POST",
    "/v1/native-mcps/remove",
    {
      body: RemoveNativeMcpRequest
    }
  ),
  apiTool(
    "native_mcps.removals",
    "List parked native MCP removals.",
    "GET",
    "/v1/native-mcps/removals"
  ),
  apiTool(
    "native_mcps.restore",
    "Restore a parked native MCP removal.",
    "POST",
    "/v1/native-mcps/removals/:id/restore"
  ),
  apiTool(
    "native_mcps.set_enabled",
    "Enable or disable a native harness MCP.",
    "POST",
    "/v1/native-mcps/set-enabled",
    {
      body: SetNativeMcpEnabledRequest
    }
  ),
  apiTool("skills.list", "List global and harness-local skills.", "GET", "/v1/skills"),
  apiTool(
    "skills.create",
    "Create a global skill in Codevisor's canonical store.",
    "POST",
    "/v1/skills",
    {
      body: CreateSkillRequest
    }
  ),
  apiTool(
    "skills.import_local",
    "Import a skill directory from the server filesystem.",
    "POST",
    "/v1/skills/import",
    {
      body: ImportSkillRequest
    }
  ),
  apiTool(
    "skills.discover_remote",
    "Discover skills offered by a remote source.",
    "POST",
    "/v1/skills/discover-remote",
    {
      body: DiscoverRemoteSkillsRequest
    }
  ),
  apiTool(
    "skills.import_remote",
    "Import skills from a Git or well-known remote source.",
    "POST",
    "/v1/skills/import-remote",
    {
      body: ImportRemoteSkillRequest
    }
  ),
  apiTool(
    "skills.make_global",
    "Promote a harness-local skill into the global store.",
    "POST",
    "/v1/skills/make-global",
    {
      body: MakeSkillGlobalRequest
    }
  ),
  apiTool(
    "skills.sync",
    "Synchronize global skills into agent harnesses.",
    "POST",
    "/v1/skills/sync",
    {
      body: SyncSkillsRequest
    }
  ),
  apiTool(
    "skills.set_installed",
    "Install or uninstall one skill for one harness.",
    "PUT",
    "/v1/skills/:name/harnesses/:harnessId",
    {
      body: SetSkillInstalledRequest
    }
  )
]
