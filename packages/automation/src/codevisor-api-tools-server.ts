import {
  AddMachineRequest,
  CreateProjectFromGitRequest,
  CreateProjectRequest,
  CreateScratchProjectRequest,
  CreateWorktreeRequest,
  PromoteWorkspacePaneToChatRequest,
  ReorderWorkspacePanesRequest,
  UpdateProjectRequest,
  UpdateWorkspacePaneRequest,
  UpdateWorkspaceRequest,
  UpsertWorkspacePaneRequest,
  UpsertWorkspaceRequest
} from "@codevisor/api"

import {
  stringQuery,
  booleanQuery,
  integerQuery,
  cloudConnectBody,
  apiTool,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

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
    "machines.list",
    "List every machine on this account (this one and every cloud-connected machine) with its stable id, name, OS, online state, and last-seen time. `isCurrent` marks the machine this call runs on; `ephemeral` ({ provider, ownerDeviceId }) marks a sandbox.",
    "GET",
    "/v1/machines"
  ),
  apiTool(
    "machines.add",
    "Add a host to the user's Codevisor account over SSH, with no human approval: from this " +
      "machine (using its SSH keys and ~/.ssh/config), install Codevisor on the host, join it " +
      "to the account with a one-time invite, and wait until it's online. Use for requests like " +
      "'set up my new VPS as a Codevisor machine'. `ssh` is a destination like root@203.0.113.7 " +
      "or a Host alias; the host needs curl and key-based SSH access from this machine. " +
      "Takes a few minutes. Returns the new machine (also in machines.list()). Same as " +
      "`codevisor machines add`.",
    "POST",
    "/v1/machines/add",
    { body: AddMachineRequest }
  ),
  apiTool(
    "machines.invite",
    "Create a one-time code (valid ~10 minutes) that adds one new machine to the user's " +
      "account without a human approval, for hosts machines.add can't reach over SSH (cloud-init " +
      "user data, a web console, a container). On the new host: install Codevisor with " +
      "CODEVISOR_INVITE=<code> set, or run `codevisor auth login --invite -` with the code on " +
      "stdin. The code is a secret: never print it to the user or write it to a file you keep. " +
      "Same as `codevisor machines invite`.",
    "POST",
    "/v1/machines/invite"
  ),
  apiTool(
    "machines.remove",
    "Remove another machine (by id or name from machines.list()) from the user's account: it " +
      "disconnects and must sign in again to come back. Confirm with the user first. Same as " +
      "`codevisor machines remove`.",
    "DELETE",
    "/v1/machines/:machineId",
    { confirm: true }
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
    "Connect this machine to a Codevisor Cloud account, with a person's session (serverUrl + " +
      "sessionToken) or a one-time machine invite (inviteCode from machines.invite).",
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
    "Get Browser Use availability on the server machine: Chrome, the extension, and managed Chromium.",
    "GET",
    "/v1/browser-use"
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
  apiTool(
    "workspaces.list",
    "List durable pane-workspace identities, including their labels.",
    "GET",
    "/v1/workspaces",
    {
      query: [
        stringQuery(
          "label",
          "Only workspaces carrying this label, as key=value (or just key for any value)."
        )
      ]
    }
  ),
  apiTool(
    "workspaces.snapshot",
    "Read a coherent snapshot of workspaces and their panes.",
    "GET",
    "/v1/workspace-snapshot"
  ),
  apiTool(
    "workspaces.panes_list",
    "List durable panes across workspaces. Layout and focus are client-specific; use clients.context for those.",
    "GET",
    "/v1/workspace-panes"
  ),
  apiTool(
    "workspaces.pane_upsert",
    "Create or replace a shared pane identity. Built-ins use providerId codevisor and paneType chat, terminal, browser, or markdown. A chat references resourceKind session and its session id; markdown references resourceKind file and its path. Plugins use providerId plugin:<plugin id from plugins.list> and a paneType from that plugin's capabilities.panes. Use clients.navigate to select the synchronized pane in a particular client.",
    "PUT",
    "/v1/workspaces/:workspaceId/panes/:paneId",
    { body: UpsertWorkspacePaneRequest }
  ),
  apiTool(
    "workspaces.pane_update",
    "Update pane content or title without replacing the entire record.",
    "PATCH",
    "/v1/workspaces/:workspaceId/panes/:paneId",
    { body: UpdateWorkspacePaneRequest }
  ),
  apiTool(
    "workspaces.pane_promote_chat",
    "Convert an existing pane into a chat, preserving its pane identity and workspace membership.",
    "POST",
    "/v1/workspaces/:workspaceId/panes/:paneId/promote-chat",
    { body: PromoteWorkspacePaneToChatRequest }
  ),
  apiTool(
    "workspaces.pane_close",
    "Close a shared pane. Closing the final pane leaves the workspace empty; clients show their local New Tab page. This affects every client; it does not delete the chat session.",
    "POST",
    "/v1/workspaces/:workspaceId/panes/:paneId/close"
  ),
  apiTool(
    "workspaces.upsert",
    "Create or fully replace a workspace identity by id. labels (string key/value pairs) are kept when omitted; an empty object clears them.",
    "PUT",
    "/v1/workspaces/:id",
    {
      body: UpsertWorkspaceRequest
    }
  ),
  apiTool(
    "workspaces.update",
    "Rename, re-home, relabel, or archive a workspace identity. labels replaces the workspace's labels; an empty object clears them.",
    "PATCH",
    "/v1/workspaces/:id",
    {
      body: UpdateWorkspaceRequest
    }
  ),
  apiTool(
    "workspaces.panes_reorder",
    "Reorder a workspace's tabs on every client. paneIds lists pane ids in the order they should appear (see workspaces.panes_list); panes left out keep their relative order after them. Splits stay device-local; a split's panes move together as one tab.",
    "POST",
    "/v1/workspaces/:workspaceId/panes/reorder",
    { body: ReorderWorkspacePanesRequest }
  ),
  apiTool(
    "workspaces.git",
    "Get the branch a workspace is on and, when asked, its GitHub pull request. An archived worktree, whose folder is gone, reports the branch it was archived on.",
    "GET",
    "/v1/workspaces/:workspaceId/git",
    { query: [booleanQuery("pullRequest", "Also look up the branch's pull request.")] }
  ),
  apiTool(
    "workspaces.photos",
    "List images from a workspace's chats, newest first: attached images, generated images and tool screenshots, each once. Pass nextBefore back as before for the next page.",
    "GET",
    "/v1/workspaces/:workspaceId/photos",
    {
      query: [
        stringQuery("before", "nextBefore from the previous page."),
        integerQuery("limit", "Photos per page, 1-200 (default 60).")
      ]
    }
  ),
  apiTool(
    "workspaces.media",
    "List images and videos from a workspace's chats, newest first: everything workspaces.photos lists plus attached and tool-recorded videos, with each video's duration when known. Pass nextBefore back as before for the next page.",
    "GET",
    "/v1/workspaces/:workspaceId/media",
    {
      query: [
        stringQuery("before", "nextBefore from the previous page."),
        integerQuery("limit", "Items per page, 1-200 (default 60).")
      ]
    }
  ),
  apiTool(
    "workspaces.links",
    "List web links mentioned in a workspace's chats, newest first, each URL once. Pass nextBefore back as before for the next page.",
    "GET",
    "/v1/workspaces/:workspaceId/links",
    {
      query: [
        stringQuery("before", "nextBefore from the previous page."),
        integerQuery("limit", "Links per page, 1-200 (default 100).")
      ]
    }
  ),
  apiTool(
    "workspaces.files",
    "List files changed in a workspace, newest first: files its agents edited, with summed line counts, and files left uncommitted in its checkout, with git's counts.",
    "GET",
    "/v1/workspaces/:workspaceId/files"
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
      "Set providerId to `plugin:<id>` with the plugin's id from plugins.list, and paneType to " +
      "one of that plugin's capabilities.panes types. Omit metadata. paneId is " +
      "the stable pane identity: pass a new lowercase UUID to open a " +
      "new pane, or an existing pane's id to replace it.",
    "PUT",
    "/v1/workspaces/:workspaceId/panes/:paneId",
    {
      body: UpsertWorkspacePaneRequest
    }
  )
]
