import { Schema } from "effect"

/// Wire protocol version a plugin manifest targets. The server rejects
/// manifests whose protocolVersion it does not understand, so future breaking
/// manifest changes bump this and old servers fail loudly instead of
/// misreading the file.
export const PLUGINS_PROTOCOL_VERSION = 1

/// One pane a plugin contributes. `path` is the plugin-server path the pane's
/// webview loads through the proxy; it must both start and end with `/` so
/// every relative URL inside the pane document resolves under the proxied
/// prefix (the whole reason no HTML rewriting is needed).
export const PluginPaneDescriptor = Schema.Struct({
  /// Pane type, unique within the plugin (e.g. "diff").
  type: Schema.String,
  title: Schema.String,
  path: Schema.String,
  /// Optional SF Symbol name for pane chrome; clients fall back to a generic
  /// plugin symbol.
  icon: Schema.optional(Schema.String)
})
export type PluginPaneDescriptor = typeof PluginPaneDescriptor.Type

export const PluginCommand = Schema.Struct({
  command: Schema.String
})
export type PluginCommand = typeof PluginCommand.Type

/// One agent tool a plugin contributes. When an agent invokes it, the server
/// POSTs the JSON arguments to `path` on the plugin's loopback server. Unlike
/// pane paths, `path` needs no trailing slash — it is an RPC endpoint, not a
/// document resolving relative URLs.
export const PluginToolDescriptor = Schema.Struct({
  /// Tool name, unique within the plugin: lowercase letters, digits, and
  /// underscores (e.g. "notes_add").
  name: Schema.String,
  /// Shown to agents in tool catalogs and to users on install consent
  /// surfaces alongside the run commands.
  description: Schema.String,
  path: Schema.String,
  /// Optional JSON Schema for the tool's arguments, passed through verbatim
  /// to agents. Absent means "any JSON object".
  inputSchema: Schema.optional(Schema.Unknown)
})
export type PluginToolDescriptor = typeof PluginToolDescriptor.Type

/// codevisor-plugin.json — the contract between a plugin directory and the
/// server. Deliberately small: a plugin is any executable that serves HTTP on
/// $PORT; everything else here is metadata the app renders without running
/// the plugin (lazy activation).
export const PluginManifest = Schema.Struct({
  protocolVersion: Schema.Number,
  /// Owner-namespaced id, lowercase `owner.name`. Validated against the
  /// install source on managed installs so a repo cannot impersonate another
  /// plugin.
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  /// Agent tools this plugin exposes to the model through the MCP gateway.
  /// Tool-only plugins (empty panes + tools) are first-class.
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// Run once at install/update time (dependency fetch, build). Absent for
  /// zero-dependency plugins — the documented golden path.
  install: Schema.optional(PluginCommand),
  /// Launches the plugin server; receives PORT, CODEVISOR_PLUGIN_ID, and
  /// CODEVISOR_PLUGIN_DATA_DIR in its environment.
  run: PluginCommand,
  /// process.platform allowlist; absent means all platforms.
  platforms: Schema.optional(Schema.Array(Schema.String)),
  /// Idle shutdown after this many seconds with no connected panes.
  /// 0 disables idle shutdown. Default 300.
  idleTimeoutSeconds: Schema.optional(Schema.Number),
  /// Optional HTTP readiness path (must return 2xx). Absent: a successful
  /// TCP connect to the assigned port counts as ready.
  healthPath: Schema.optional(Schema.String)
})
export type PluginManifest = typeof PluginManifest.Type

export const PluginRuntimeState = Schema.Literals([
  "stopped",
  "starting",
  "running",
  "stopping",
  "failed"
])
export type PluginRuntimeState = typeof PluginRuntimeState.Type

/// How a plugin arrived in ~/.codevisor/plugins: "managed" directories were
/// installed (and may be deleted) by Codevisor; "linked" ones belong to the
/// developer and are never touched.
export const PluginSource = Schema.Literals(["managed", "linked"])
export type PluginSource = typeof PluginSource.Type

export const PluginSummary = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  /// Agent tools the plugin declares; absent when it declares none.
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  source: PluginSource,
  path: Schema.String,
  state: PluginRuntimeState,
  /// How many workspace pane records currently point at this plugin
  /// (providerId `plugin:<id>`). Route-layer enrichment: the plugin manager
  /// itself has no database access, so only the HTTP responses carry it.
  openPaneCount: Schema.optional(Schema.Number)
})
export type PluginSummary = typeof PluginSummary.Type

export const PluginListResponse = Schema.Struct({
  plugins: Schema.Array(PluginSummary)
})
export type PluginListResponse = typeof PluginListResponse.Type

/// Requests a short-lived pane token. The webview cannot attach Authorization
/// headers to subresource loads (and the cloud relay strips them), so pane
/// traffic authenticates with this token: carried on the initial navigation
/// as ?codevisorPaneToken=…, exchanged by the proxy for a scoped HttpOnly
/// cookie.
export const PluginPaneTokenRequest = Schema.Struct({
  paneType: Schema.String,
  workspaceId: Schema.optional(Schema.String),
  /// Working directory the pane should operate on (typically the workspace
  /// root); forwarded to the plugin in X-Codevisor-Context.
  cwd: Schema.optional(Schema.String),
  /// "light" | "dark" hint forwarded so plugins can server-render themed HTML.
  themeMode: Schema.optional(Schema.String)
})
export type PluginPaneTokenRequest = typeof PluginPaneTokenRequest.Type

export const PluginPaneTokenResponse = Schema.Struct({
  token: Schema.String,
  /// Server-relative pane URL (path + query) ready to load in a webview
  /// against the machine's base URL.
  path: Schema.String,
  /// Absolute pane URL against the origin the caller reached the server on —
  /// for opening the pane in browser tooling. Native clients keep composing
  /// `path` against their machine base URL.
  url: Schema.optional(Schema.String),
  expiresAt: Schema.String
})
export type PluginPaneTokenResponse = typeof PluginPaneTokenResponse.Type

/// Ask the server to stage a plugin source (GitHub `owner/repo` shorthand,
/// git URL, or a local path on the server's machine) and describe what an
/// install would do — without installing anything.
export const DiscoverRemotePluginRequest = Schema.Struct({
  source: Schema.String
})
export type DiscoverRemotePluginRequest = typeof DiscoverRemotePluginRequest.Type

/// What a staged plugin source offers. `installCommand`/`runCommand` are the
/// VERBATIM manifest command strings: install consent surfaces (the macOS
/// sheet, the CLI prompt, agent approval cards) show exactly these before
/// anything runs on the user's machine.
export const DiscoverRemotePluginResult = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  /// Agent tools installation would add — consent surfaces list these
  /// alongside the verbatim commands.
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// Run once at install time, in the plugin directory. Absent for
  /// zero-dependency plugins.
  installCommand: Schema.optional(Schema.String),
  /// Runs the plugin server whenever a pane needs it.
  runCommand: Schema.String,
  /// A plugin with this id is already installed on the machine; importing
  /// again updates a managed install (and conflicts with a linked one).
  alreadyInstalled: Schema.Boolean
})
export type DiscoverRemotePluginResult = typeof DiscoverRemotePluginResult.Type

/// Install a plugin from a remote source into the plugins root. The consent
/// step is client-side: callers are expected to have shown the discovery
/// result (including the verbatim commands) first.
export const ImportRemotePluginRequest = Schema.Struct({
  source: Schema.String
})
export type ImportRemotePluginRequest = typeof ImportRemotePluginRequest.Type

/// Symlink a local plugin directory (absolute path on the server's machine)
/// into the plugins root — dev mode. Linked plugins are never deleted by
/// uninstall.
export const LinkPluginRequest = Schema.Struct({
  path: Schema.String
})
export type LinkPluginRequest = typeof LinkPluginRequest.Type

/// One plugin in the public registry index: manifest metadata the app can
/// render without running anything, plus the GitHub facts (repo, stars, push
/// time) that anchor it to a real owner. Mirrors the entries the cloud
/// registry serves at /plugins/index.json (apps/cloud/src/plugin-registry.ts).
export const PluginRegistryEntry = Schema.Struct({
  /// Owner-namespaced plugin id, lowercase `owner.name`.
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// GitHub "owner/name" — the directory always shows the real repo owner.
  /// Feed this to the discover→consent→install flow as the plugin source.
  repo: Schema.String,
  stars: Schema.Number,
  pushedAt: Schema.String
})
export type PluginRegistryEntry = typeof PluginRegistryEntry.Type

/// Why a tagged repo was left out of the index — published alongside the
/// entries so plugin authors can see exactly what disqualified them.
export const PluginRegistryRejection = Schema.Struct({
  repo: Schema.String,
  reason: Schema.String
})
export type PluginRegistryRejection = typeof PluginRegistryRejection.Type

/// The whole registry index (`GET /v1/plugins/registry`): the machine fetches
/// and caches the hosted index so clients only ever talk to their machine.
export const PluginRegistryIndex = Schema.Struct({
  generatedAt: Schema.String,
  entries: Schema.Array(PluginRegistryEntry),
  rejected: Schema.Array(PluginRegistryRejection)
})
export type PluginRegistryIndex = typeof PluginRegistryIndex.Type

/// Invoke one plugin-declared agent tool. `args` should match the tool's
/// declared inputSchema — the server passes them through verbatim and the
/// plugin validates. The response body is whatever the tool returns.
export const InvokePluginToolRequest = Schema.Struct({
  args: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
  /// Optional caller context forwarded to the plugin inside the signed
  /// X-Codevisor-Context header.
  workspaceId: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String)
})
export type InvokePluginToolRequest = typeof InvokePluginToolRequest.Type
