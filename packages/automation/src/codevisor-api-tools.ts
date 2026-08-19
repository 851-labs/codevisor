import {
  AnswerOpenCodeAuthRequest,
  AnswerPiAuthRequest,
  CancelRequest,
  CreateHarnessAccountRequest,
  CreateMcpServerRequest,
  CreateProjectFromGitRequest,
  CreateProjectRequest,
  CreateScratchProjectRequest,
  CreateSessionRequest,
  CreateSkillRequest,
  CreateWorktreeRequest,
  CustomHarnessSpec,
  DetectMcpAuthRequest,
  DiscoverRemotePluginRequest,
  DiscoverRemoteSkillsRequest,
  ImportNativeMcpsRequest,
  ImportRemotePluginRequest,
  ImportRemoteSkillRequest,
  ImportSkillRequest,
  MakeSkillGlobalRequest,
  MarkSessionReadRequest,
  OpenSessionRequest,
  PluginPaneTokenRequest,
  PromptRequest,
  RemoveNativeMcpRequest,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetNativeMcpEnabledRequest,
  SetQuestionAnswerRequest,
  SetSkillInstalledRequest,
  StartHarnessLoginRequest,
  StartOpenCodeAuthRequest,
  StartPiAuthRequest,
  SyncSkillsRequest,
  TerminalCreateRequest,
  UpdateBrowserUseConfigurationRequest,
  UpdateHarnessAccountRequest,
  UpdateHarnessRequest,
  UpdateMcpServerRequest,
  UpdateProjectRequest,
  UpdateQueuedPromptRequest,
  UpdateSessionRequest,
  UpdateWorkspaceRequest,
  UpsertWorkspacePaneRequest,
  UpsertWorkspaceRequest
} from "@codevisor/api"
import { Schema } from "effect"

export type JsonSchema = Record<string, unknown>
export type HttpMethod = "DELETE" | "GET" | "PATCH" | "POST" | "PUT"

export interface QueryParameter {
  readonly name: string
  readonly schema: JsonSchema
  readonly description?: string | undefined
}

export interface CodevisorApiToolSpec {
  readonly name: string
  readonly description: string
  readonly method: HttpMethod
  readonly path: string
  readonly body?: Schema.Constraint | undefined
  readonly wrappedBody?: boolean | undefined
  readonly query?: ReadonlyArray<QueryParameter> | undefined
  readonly response?: "binary" | undefined
  /// Consent gate: the tool grows a required boolean `confirm` argument that
  /// is never forwarded to the server, and the provider refuses to send the
  /// request unless it is exactly `true`. Used where an agent action runs
  /// commands on the user's machine (e.g. plugin install) and the agent must
  /// first show the user what will happen and receive explicit approval.
  readonly confirm?: boolean | undefined
}

const stringQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "string" },
  ...(description === undefined ? {} : { description })
})

const booleanQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "boolean" },
  ...(description === undefined ? {} : { description })
})

const integerQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "integer", minimum: 0 },
  ...(description === undefined ? {} : { description })
})

export const objectSchema = (schema: Schema.Constraint): JsonSchema => {
  const document = Schema.toJsonSchemaDocument(schema, {
    additionalProperties: false,
    generateDescriptions: true
  })
  return { ...document.schema, $defs: document.definitions }
}

const enabledBody = Schema.Struct({ enabled: Schema.Boolean })
const cloudConnectBody = Schema.Struct({ serverUrl: Schema.String, sessionToken: Schema.String })
const harnessInstallBody = Schema.Struct({ methodId: Schema.optional(Schema.String) })

const apiTool = (
  name: string,
  description: string,
  method: HttpMethod,
  path: string,
  options: Omit<CodevisorApiToolSpec, "description" | "method" | "name" | "path"> = {}
): CodevisorApiToolSpec => ({ name, description, method, path, ...options })

/// The server-only Codevisor control plane. Every entry delegates to the same
/// authenticated /v1 route used by native clients, so validation, durable
/// events, idempotency, and lifecycle side effects have one implementation.
export const CODEVISOR_API_TOOLS: ReadonlyArray<CodevisorApiToolSpec> = [
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
      "pane type from the plugin's manifest (see plugins.list), and metadata to the JSON string " +
      '`{"icon":"<icon>","paneType":"<paneType>","pluginId":"<pluginId>"}` with keys in exactly ' +
      "that order, omitting icon when the manifest pane has none — clients compare this string " +
      "byte-for-byte. paneId is the stable pane identity: pass a new lowercase UUID to open a " +
      "new pane, or an existing pane's id to replace it.",
    "PUT",
    "/v1/workspaces/:workspaceId/panes/:paneId",
    {
      body: UpsertWorkspacePaneRequest
    }
  ),

  apiTool("sessions.list", "List Codevisor sessions on this server.", "GET", "/v1/sessions"),
  apiTool("sessions.create", "Create a Codevisor coding-agent session.", "POST", "/v1/sessions", {
    body: CreateSessionRequest
  }),
  apiTool(
    "sessions.get",
    "Get a session, its current conversation, queue, and goal.",
    "GET",
    "/v1/sessions/:id"
  ),
  apiTool(
    "sessions.open",
    "Create or open a session and return its first transcript page.",
    "POST",
    "/v1/sessions/:id/open",
    {
      body: OpenSessionRequest
    }
  ),
  apiTool(
    "sessions.update",
    "Rename, archive, move, or reconfigure a session.",
    "PATCH",
    "/v1/sessions/:id",
    {
      body: UpdateSessionRequest
    }
  ),
  apiTool("sessions.delete", "Delete a Codevisor session.", "DELETE", "/v1/sessions/:id"),
  apiTool(
    "sessions.connect",
    "Ensure the session's underlying agent runtime is connected.",
    "POST",
    "/v1/sessions/:id/connect"
  ),
  apiTool(
    "sessions.usage_limits",
    "Read account usage limits for a session's harness.",
    "GET",
    "/v1/sessions/:id/usage-limits"
  ),
  apiTool(
    "sessions.branch_diff",
    "Get added and removed line totals for a session workspace.",
    "GET",
    "/v1/sessions/:id/branch-diff"
  ),
  apiTool(
    "sessions.transcript",
    "Read a reverse-paginated session transcript.",
    "GET",
    "/v1/sessions/:id/transcript",
    {
      query: [integerQuery("before", "Exclusive transcript cursor."), integerQuery("limit")]
    }
  ),
  apiTool(
    "sessions.transcript_details",
    "Read the detailed events for one transcript item.",
    "GET",
    "/v1/sessions/:id/transcript/:itemId/details"
  ),
  apiTool(
    "sessions.events",
    "Read the persisted event history for a session.",
    "GET",
    "/v1/sessions/:id/events"
  ),
  apiTool(
    "sessions.queue_list",
    "List queued prompts for a session.",
    "GET",
    "/v1/sessions/:id/queue"
  ),
  apiTool(
    "sessions.queue_update",
    "Edit a queued prompt before it starts.",
    "PATCH",
    "/v1/sessions/:id/queue/:queueId",
    {
      body: UpdateQueuedPromptRequest
    }
  ),
  apiTool(
    "sessions.queue_delete",
    "Remove a queued prompt.",
    "DELETE",
    "/v1/sessions/:id/queue/:queueId"
  ),
  apiTool(
    "sessions.prompt",
    "Send or queue a prompt in a Codevisor session.",
    "POST",
    "/v1/sessions/:id/prompt",
    {
      body: PromptRequest
    }
  ),
  apiTool(
    "sessions.cancel",
    "Cancel the active turn in a session.",
    "POST",
    "/v1/sessions/:id/cancel",
    {
      body: CancelRequest
    }
  ),
  apiTool("sessions.mode_set", "Set a session's agent mode.", "POST", "/v1/sessions/:id/mode", {
    body: SetModeRequest
  }),
  apiTool(
    "sessions.config_set",
    "Set one session configuration option.",
    "POST",
    "/v1/sessions/:id/config",
    {
      body: SetConfigRequest
    }
  ),
  apiTool(
    "sessions.goal_set",
    "Create or update a persistent session goal.",
    "POST",
    "/v1/sessions/:id/goal",
    {
      body: SetGoalRequest
    }
  ),
  apiTool(
    "sessions.goal_clear",
    "Clear a session's persistent goal.",
    "DELETE",
    "/v1/sessions/:id/goal"
  ),
  apiTool(
    "sessions.question_answer",
    "Answer or cancel a blocking agent question.",
    "POST",
    "/v1/sessions/:id/questions/:questionId/answer",
    {
      body: SetQuestionAnswerRequest
    }
  ),
  apiTool(
    "sessions.mark_read",
    "Mark session attention events as read.",
    "POST",
    "/v1/sessions/:id/read",
    {
      body: MarkSessionReadRequest
    }
  ),
  apiTool(
    "sessions.mark_unread",
    "Mark a session manually unread.",
    "POST",
    "/v1/sessions/:id/unread"
  ),
  apiTool(
    "sessions.plan_approval_clear",
    "Clear a pending plan-approval state.",
    "DELETE",
    "/v1/sessions/:id/plan-approval"
  ),

  apiTool(
    "terminals.create",
    "Create or reattach a server-side terminal.",
    "POST",
    "/v1/terminals",
    {
      body: TerminalCreateRequest
    }
  ),
  apiTool(
    "terminals.close_session",
    "Close the live terminal associated with a session key.",
    "DELETE",
    "/v1/terminals/session/:sessionId"
  ),
  apiTool(
    "files.upload",
    "Upload a base64-encoded file to Codevisor for prompt attachments.",
    "POST",
    "/v1/files",
    {
      query: [stringQuery("name"), stringQuery("mimeType")]
    }
  ),
  apiTool(
    "files.download",
    "Download a Codevisor attachment as an MCP binary resource.",
    "GET",
    "/v1/files/:id",
    {
      response: "binary"
    }
  ),

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
  ),
  apiTool("skills.delete", "Delete a global skill.", "DELETE", "/v1/skills/:name"),

  apiTool(
    "plugins.list",
    "List installed Codevisor plugins with their panes and runtime state.",
    "GET",
    "/v1/plugins"
  ),
  apiTool(
    "plugins.discover_remote",
    "Preview a plugin source without installing it: returns the manifest summary and the exact " +
      "install/run commands installation would execute on this machine. ALWAYS call this before " +
      "plugins.install and show the user the result.",
    "POST",
    "/v1/plugins/discover-remote",
    {
      body: DiscoverRemotePluginRequest
    }
  ),
  apiTool(
    "plugins.install",
    "Install (or update) a plugin from a remote source, running its install command on the " +
      "user's machine. Mandatory first step: call plugins.discover_remote and show the user the " +
      "discovered manifest and verbatim commands. Only set confirm=true after the user " +
      "explicitly approves.",
    "POST",
    "/v1/plugins/import-remote",
    {
      body: ImportRemotePluginRequest,
      confirm: true
    }
  ),
  apiTool(
    "plugins.remove",
    "Uninstall a managed plugin: stop its process and delete its directory. Linked (dev-mode) " +
      "plugins are never deleted this way.",
    "DELETE",
    "/v1/plugins/:pluginId"
  ),
  apiTool(
    "plugins.restart",
    "Restart a plugin's server process, clearing a failed state.",
    "POST",
    "/v1/plugins/:pluginId/restart"
  ),
  apiTool(
    "plugins.open_pane_url",
    "Issue a pane URL for a plugin pane, then open it with the browser tools to view and " +
      "interact with it. The browser view is an independent view of the same pane: it shares " +
      "live server state with the user's open panes. Use the workspace pane's id as paneId " +
      "when one exists, otherwise any unique id. Pass the workspace root as cwd.",
    "POST",
    "/v1/plugins/:pluginId/panes/:paneId/token",
    {
      body: PluginPaneTokenRequest
    }
  ),

  apiTool("harnesses.list", "List agent harnesses and readiness state.", "GET", "/v1/harnesses", {
    query: [{ name: "include", schema: { type: "string", enum: ["lifecycle"] } }]
  }),
  apiTool(
    "harnesses.rescan",
    "Refresh the shell environment and rescan harnesses.",
    "POST",
    "/v1/harnesses/rescan"
  ),
  apiTool(
    "harnesses.auth_refresh",
    "Refresh harness authentication state.",
    "POST",
    "/v1/harnesses/auth/refresh",
    {
      query: [stringQuery("harnessId")]
    }
  ),
  apiTool(
    "harnesses.check_updates",
    "Check installed harnesses for updates.",
    "POST",
    "/v1/harnesses/check-updates"
  ),
  apiTool(
    "harnesses.update_settings",
    "Enable or disable an agent harness.",
    "PATCH",
    "/v1/harnesses/:id",
    {
      body: UpdateHarnessRequest
    }
  ),
  apiTool(
    "harnesses.install",
    "Begin installing an agent harness.",
    "POST",
    "/v1/harnesses/:id/install",
    {
      body: harnessInstallBody
    }
  ),
  apiTool(
    "harnesses.update",
    "Begin updating an installed CLI harness.",
    "POST",
    "/v1/harnesses/:id/update"
  ),
  apiTool(
    "harnesses.pending_update_apply",
    "Apply a pending harness update now.",
    "POST",
    "/v1/harnesses/:id/update/pending/apply"
  ),
  apiTool(
    "harnesses.pending_update_cancel",
    "Cancel a pending harness update.",
    "DELETE",
    "/v1/harnesses/:id/update/pending"
  ),
  apiTool(
    "harnesses.bundled_app",
    "Get bundled desktop-app information for a harness.",
    "GET",
    "/v1/harnesses/:id/bundled-app"
  ),
  apiTool(
    "harnesses.bundled_app_update",
    "Begin updating a harness's bundled desktop app.",
    "POST",
    "/v1/harnesses/:id/bundled-app/update"
  ),
  apiTool(
    "harnesses.agent_sessions",
    "List sessions from a harness's own native store.",
    "GET",
    "/v1/harnesses/:id/agent-sessions"
  ),
  apiTool(
    "harnesses.custom_list",
    "List user-defined ACP harness specifications.",
    "GET",
    "/v1/harnesses/custom"
  ),
  apiTool(
    "harnesses.custom_replace",
    "Replace all user-defined ACP harness specifications.",
    "PUT",
    "/v1/harnesses/custom",
    {
      body: Schema.Array(CustomHarnessSpec),
      wrappedBody: true
    }
  ),
  apiTool(
    "harnesses.custom_test",
    "Test an ACP handshake for a custom harness specification.",
    "POST",
    "/v1/harnesses/custom/test",
    {
      body: CustomHarnessSpec
    }
  ),
  apiTool(
    "harnesses.accounts_list",
    "List accounts configured for a harness.",
    "GET",
    "/v1/harnesses/:id/accounts"
  ),
  apiTool(
    "harnesses.accounts_create",
    "Create an account profile for a harness.",
    "POST",
    "/v1/harnesses/:id/accounts",
    {
      body: CreateHarnessAccountRequest
    }
  ),
  apiTool(
    "harnesses.accounts_update",
    "Rename a harness account profile.",
    "PATCH",
    "/v1/harnesses/:id/accounts/:accountId",
    {
      body: UpdateHarnessAccountRequest
    }
  ),
  apiTool(
    "harnesses.accounts_delete",
    "Delete a harness account profile.",
    "DELETE",
    "/v1/harnesses/:id/accounts/:accountId"
  ),
  apiTool(
    "harnesses.accounts_activate",
    "Make a harness account active.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/activate"
  ),
  apiTool(
    "harnesses.accounts_probe",
    "Probe and refresh one harness account's authentication.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/auth/probe"
  ),
  apiTool(
    "harnesses.accounts_login",
    "Start authentication for a harness account.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/login",
    {
      body: StartHarnessLoginRequest
    }
  ),
  apiTool(
    "harnesses.accounts_login_cancel",
    "Cancel a harness-account login flow.",
    "DELETE",
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId"
  ),
  apiTool(
    "harnesses.accounts_logout",
    "Log out a harness account.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/logout"
  ),
  apiTool(
    "harnesses.pi_providers",
    "List authentication providers supported by Pi.",
    "GET",
    "/v1/harnesses/pi/providers"
  ),
  apiTool(
    "harnesses.pi_login",
    "Start a Pi provider login flow.",
    "POST",
    "/v1/harnesses/pi/providers/:providerId/login",
    {
      body: StartPiAuthRequest
    }
  ),
  apiTool(
    "harnesses.pi_logout",
    "Log out a Pi provider.",
    "DELETE",
    "/v1/harnesses/pi/providers/:providerId"
  ),
  apiTool(
    "harnesses.pi_flow_get",
    "Get a Pi authentication flow.",
    "GET",
    "/v1/harnesses/pi/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.pi_flow_answer",
    "Answer a Pi authentication-flow prompt.",
    "POST",
    "/v1/harnesses/pi/auth-flows/:flowId/answer",
    {
      body: AnswerPiAuthRequest
    }
  ),
  apiTool(
    "harnesses.pi_flow_cancel",
    "Cancel a Pi authentication flow.",
    "DELETE",
    "/v1/harnesses/pi/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.opencode_providers",
    "List OpenCode authentication providers for an account.",
    "GET",
    "/v1/harnesses/opencode/accounts/:accountId/providers"
  ),
  apiTool(
    "harnesses.opencode_login",
    "Start an OpenCode provider login flow.",
    "POST",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId/login",
    {
      body: StartOpenCodeAuthRequest
    }
  ),
  apiTool(
    "harnesses.opencode_logout",
    "Log out an OpenCode provider.",
    "DELETE",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId"
  ),
  apiTool(
    "harnesses.opencode_flow_get",
    "Get an OpenCode authentication flow.",
    "GET",
    "/v1/harnesses/opencode/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.opencode_flow_answer",
    "Answer an OpenCode authentication-flow prompt.",
    "POST",
    "/v1/harnesses/opencode/auth-flows/:flowId/answer",
    {
      body: AnswerOpenCodeAuthRequest
    }
  ),
  apiTool(
    "harnesses.opencode_flow_cancel",
    "Cancel an OpenCode authentication flow.",
    "DELETE",
    "/v1/harnesses/opencode/auth-flows/:flowId"
  )
]
