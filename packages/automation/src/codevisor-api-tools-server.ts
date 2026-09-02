import {
  CreateProjectFromGitRequest,
  CreateProjectRequest,
  CreateScratchProjectRequest,
  CreateWorktreeRequest,
  UpdateBrowserUseConfigurationRequest,
  UpdateProjectRequest,
  UpdateWorkspaceRequest,
  UpsertWorkspacePaneRequest,
  UpsertWorkspaceRequest
} from "@codevisor/api"
import {
  stringQuery,
  booleanQuery,
  cloudConnectBody,
  apiTool,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

/// Server, machine, settings, filesystem, project, worktree, and workspace tools.
export const codevisorServerApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool("server.health", "Check the current Codevisor server's health.", "GET", "/v1/health"),
  apiTool(
    "server.discovery",
    "Get this machine's tokenless Codevisor discovery manifest.",
    "GET",
    "/v1/discovery"
  ),
  apiTool("server.info", "Get server and machine identity information.", "GET", "/v1/info"),
  apiTool(
    "server.openapi",
    "Get the Codevisor server's OpenAPI document.",
    "GET",
    "/v1/openapi.json"
  ),
  apiTool(
    "machines.tailnet_peers",
    "List machines visible on this server's tailnet.",
    "GET",
    "/v1/tailnet/peers"
  ),
  apiTool("server.update_status", "Check for a Codevisor server update.", "GET", "/v1/update", {
    query: [
      booleanQuery("refresh", "Bypass the cached update result."),
      { name: "channel", schema: { type: "string", enum: ["stable", "alpha"] } }
    ]
  }),
  apiTool(
    "server.apply_update",
    "Apply an available Codevisor server update.",
    "POST",
    "/v1/update/apply",
    {
      query: [{ name: "channel", schema: { type: "string", enum: ["stable", "alpha"] } }]
    }
  ),
  apiTool("server.shutdown", "Shut down the current Codevisor server.", "POST", "/v1/shutdown"),
  apiTool(
    "server.capabilities",
    "Inspect available harness modes and configuration.",
    "GET",
    "/v1/capabilities",
    {
      query: [
        stringQuery("cwd", "Working directory used to resolve harness capabilities."),
        stringQuery("harnessId")
      ]
    }
  ),
  apiTool(
    "machines.pairing_token_create",
    "Issue a short-lived machine pairing token.",
    "POST",
    "/v1/auth/pairing-token"
  ),
  apiTool(
    "machines.connection_token_get",
    "Get this machine's stable connection token.",
    "GET",
    "/v1/auth/connection-token"
  ),
  apiTool(
    "machines.connection_token_rotate",
    "Rotate this machine's stable connection token.",
    "POST",
    "/v1/auth/connection-token/rotate"
  ),
  apiTool(
    "machines.cloud_status",
    "Get this machine's Codevisor Cloud registration state.",
    "GET",
    "/v1/cloud"
  ),
  apiTool(
    "machines.cloud_connect",
    "Connect this machine to a Codevisor Cloud account.",
    "POST",
    "/v1/cloud/connect",
    {
      body: cloudConnectBody
    }
  ),
  apiTool(
    "machines.cloud_disconnect",
    "Disconnect this machine from Codevisor Cloud.",
    "POST",
    "/v1/cloud/disconnect"
  ),
  apiTool(
    "settings.browser_get",
    "Get server-owned Browser Use settings and availability.",
    "GET",
    "/v1/browser-use"
  ),
  apiTool(
    "settings.browser_update",
    "Update the server's preferred Browser Use backend.",
    "PATCH",
    "/v1/browser-use",
    {
      body: UpdateBrowserUseConfigurationRequest
    }
  ),
  apiTool(
    "filesystem.list",
    "List directories on the server machine for project selection.",
    "GET",
    "/v1/fs/list",
    {
      query: [stringQuery("path"), booleanQuery("showHidden")]
    }
  ),
  apiTool("projects.list", "List projects registered with Codevisor.", "GET", "/v1/projects"),
  apiTool(
    "projects.create",
    "Register a server folder as a Codevisor project.",
    "POST",
    "/v1/projects",
    {
      body: CreateProjectRequest
    }
  ),
  apiTool(
    "projects.clone",
    "Clone a Git remote and register it as a project.",
    "POST",
    "/v1/projects/from-git",
    {
      body: CreateProjectFromGitRequest
    }
  ),
  apiTool(
    "projects.create_scratch",
    "Create an empty scratch project and folder.",
    "POST",
    "/v1/projects/scratch",
    {
      body: CreateScratchProjectRequest
    }
  ),
  apiTool("projects.update", "Rename or archive a project.", "PATCH", "/v1/projects/:id", {
    body: UpdateProjectRequest
  }),
  apiTool("projects.delete", "Delete a project record.", "DELETE", "/v1/projects/:id"),
  apiTool(
    "worktrees.list",
    "List a project's managed Git worktrees.",
    "GET",
    "/v1/projects/:id/worktrees"
  ),
  apiTool(
    "worktrees.create",
    "Create a managed Git worktree for a project.",
    "POST",
    "/v1/projects/:id/worktrees",
    {
      body: CreateWorktreeRequest
    }
  ),
  apiTool("workspaces.list", "List durable pane-workspace identities.", "GET", "/v1/workspaces"),
  apiTool(
    "workspaces.upsert",
    "Create or fully replace a workspace identity by id.",
    "PUT",
    "/v1/workspaces/:id",
    {
      body: UpsertWorkspaceRequest
    }
  ),
  apiTool(
    "workspaces.update",
    "Rename, re-home, or archive a workspace identity.",
    "PATCH",
    "/v1/workspaces/:id",
    {
      body: UpdateWorkspaceRequest
    }
  ),
  apiTool(
    "workspaces.delete",
    "Delete an empty workspace identity.",
    "DELETE",
    "/v1/workspaces/:id"
  ),
  apiTool(
    "workspaces.open_plugin_pane",
    "Open a plugin pane in a workspace by upserting a workspace pane record. " +
      "Set providerId to `plugin:<pluginId>` (e.g. plugin:codevisor.git-diff), paneType to the " +
      "pane type from the plugin's manifest (see plugins.list). Omit metadata; plugin artwork " +
      "comes from the running plugin server and is never stored in workspace records. paneId is " +
      "the stable pane identity: pass a new lowercase UUID to open a " +
      "new pane, or an existing pane's id to replace it.",
    "PUT",
    "/v1/workspaces/:workspaceId/panes/:paneId",
    {
      body: UpsertWorkspacePaneRequest
    }
  )
]
