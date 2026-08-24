import { Schema } from "effect"

/// Latest wire protocol version a plugin manifest may target. Readers keep
/// v1 support so installed plugins continue to work after v2 becomes the
/// authoring default.
export const PLUGINS_PROTOCOL_VERSION = 2

export const SUPPORTED_PLUGIN_PROTOCOL_VERSIONS = [1, 2] as const

export const isSupportedPluginProtocolVersion = (version: number): boolean =>
  SUPPORTED_PLUGIN_PROTOCOL_VERSIONS.some((supported) => supported === version)

/// One pane a plugin contributes. `path` is the plugin-server path the pane's
/// webview loads through the proxy; it must both start and end with `/` so
/// every relative URL inside the pane document resolves under the proxied
/// prefix (the whole reason no HTML rewriting is needed).
export const PluginPaneDescriptor = Schema.Struct({
  /// Pane type, unique within the plugin (e.g. "diff").
  type: Schema.String,
  title: Schema.String,
  path: Schema.String,
  /// Optional absolute path on the plugin server to pane artwork. The path
  /// may serve SVG, PNG, or WebP and falls back to the plugin-level icon,
  /// then client-owned generic plugin chrome.
  iconPath: Schema.optional(Schema.String)
})
export type PluginPaneDescriptor = typeof PluginPaneDescriptor.Type

/// Protocol v1 command. It runs through the user's login shell and remains
/// supported for existing manifests.
export const PluginCommand = Schema.Struct({
  command: Schema.String
})
export type PluginCommand = typeof PluginCommand.Type

/// Protocol v2 command. Codevisor executes argv directly, so consent screens
/// and process launch agree on every argument.
export const PluginArgvCommand = Schema.Struct({
  argv: Schema.Array(Schema.String)
})
export type PluginArgvCommand = typeof PluginArgvCommand.Type

export const PluginSetupStep = Schema.Struct({
  argv: Schema.Array(Schema.String),
  /// process.platform allowlist for this step; absent means every platform.
  platforms: Schema.optional(Schema.Array(Schema.String))
})
export type PluginSetupStep = typeof PluginSetupStep.Type

export const PluginExecutableRequirement = Schema.Struct({
  /// Executable name resolved from the same PATH used to launch the plugin.
  name: Schema.String,
  /// Concise guidance shown when the executable is missing.
  installHint: Schema.optional(Schema.String),
  helpUrl: Schema.optional(Schema.String)
})
export type PluginExecutableRequirement = typeof PluginExecutableRequirement.Type

export const PluginRequirements = Schema.Struct({
  executables: Schema.optional(Schema.Array(PluginExecutableRequirement))
})
export type PluginRequirements = typeof PluginRequirements.Type

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

const PluginManifestBase = {
  /// Owner-namespaced id, lowercase `owner.name`. Validated against the
  /// install source on managed installs so a repo cannot impersonate another
  /// plugin.
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  /// Optional absolute path on the plugin server to the plugin's own artwork.
  /// Clients fetch it through the authenticated Codevisor server, never from
  /// the plugin's loopback origin directly.
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  /// Agent tools this plugin exposes through the MCP gateway. Tool-only
  /// plugins (empty panes + tools) are first-class.
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// process.platform allowlist; absent means all platforms.
  platforms: Schema.optional(Schema.Array(Schema.String)),
  /// Optional HTTP readiness path (must return 2xx). Absent: a successful
  /// TCP connect to the assigned port counts as ready.
  healthPath: Schema.optional(Schema.String)
}

/// Original manifest contract. Shell command strings remain readable, but
/// new plugins should publish protocol v2.
export const PluginManifestV1 = Schema.Struct({
  ...PluginManifestBase,
  protocolVersion: Schema.Literal(1),
  /// Run once at install/update time (dependency fetch, build). Absent for
  /// zero-dependency plugins — the documented golden path.
  install: Schema.optional(PluginCommand),
  /// Launches the plugin server; receives PORT, CODEVISOR_PLUGIN_ID, and
  /// CODEVISOR_PLUGIN_DATA_DIR in its environment.
  run: PluginCommand
})
export type PluginManifestV1 = typeof PluginManifestV1.Type

/// Current manifest contract. Structured commands remove shell ambiguity;
/// compatibility and runtime requirements can be checked before setup.
export const PluginManifestV2 = Schema.Struct({
  ...PluginManifestBase,
  protocolVersion: Schema.Literal(2),
  setup: Schema.optional(Schema.Array(PluginSetupStep)),
  run: PluginArgvCommand,
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements)
})
export type PluginManifestV2 = typeof PluginManifestV2.Type

/// codevisor-plugin.json — the contract between a plugin directory and the
/// server. A plugin is an executable that serves HTTP on $PORT; the manifest
/// describes how Codevisor validates, prepares, launches, and presents it.
export const PluginManifest = Schema.Union([PluginManifestV1, PluginManifestV2])
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
  iconPath: Schema.optional(Schema.String),
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
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  /// Agent tools installation would add — consent surfaces list these
  /// alongside the verbatim commands.
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// Run once at install time, in the plugin directory. Absent for
  /// zero-dependency plugins.
  installCommand: Schema.optional(Schema.String),
  /// Protocol v2 setup commands, preserved as argument arrays.
  setupCommands: Schema.optional(Schema.Array(PluginSetupStep)),
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements),
  /// Runs the plugin server while Codevisor is running.
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
  protocolVersion: Schema.Number,
  description: Schema.optional(Schema.String),
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  /// GitHub "owner/name" — the directory always shows the real repo owner.
  /// Feed this to the discover→consent→install flow as the plugin source.
  repo: Schema.String,
  /// Exact default-branch commit from which the registry read the manifest.
  commit: Schema.String,
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements),
  platforms: Schema.optional(Schema.Array(Schema.String)),
  /// GitHub avatar of the repo owner — the only artwork renderable before
  /// install (a plugin's own iconPath is served by its running server, so it
  /// is unreachable for a not-yet-installed plugin).
  ownerAvatarUrl: Schema.optional(Schema.String),
  stars: Schema.Number,
  pushedAt: Schema.String,
  /// Curation groundwork: reserved for first-party verification of an entry.
  /// The indexer never sets it yet, so it is always absent today.
  verified: Schema.optional(Schema.Boolean)
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
  /// Null until the indexer's first poll completes — the cloud serves an
  /// honest empty index rather than a 404.
  generatedAt: Schema.NullOr(Schema.String),
  entries: Schema.Array(PluginRegistryEntry),
  rejected: Schema.Array(PluginRegistryRejection)
})
export type PluginRegistryIndex = typeof PluginRegistryIndex.Type

/// Registry-update state for an installed plugin. These are deliberately
/// exhaustive so clients never infer eligibility from missing fields.
export const PluginUpdateState = Schema.Literals([
  "current",
  "available",
  "pinned",
  "incompatible",
  "sourceUnknown",
  "checkFailed"
])
export type PluginUpdateState = typeof PluginUpdateState.Type

export const PluginUpdateStatus = Schema.Struct({
  pluginId: Schema.String,
  installedVersion: Schema.String,
  state: PluginUpdateState,
  checkedAt: Schema.String,
  registryVersion: Schema.optional(Schema.String),
  /// Human-readable explanation for states that need action or context.
  reason: Schema.optional(Schema.String)
})
export type PluginUpdateStatus = typeof PluginUpdateStatus.Type

export const PluginUpdatesResponse = Schema.Struct({
  updates: Schema.Array(PluginUpdateStatus)
})
export type PluginUpdatesResponse = typeof PluginUpdatesResponse.Type

/// The commands and capabilities on one side of an update review. Commands
/// are display-safe renderings of the exact manifest values staged in the
/// plan; the staged directory remains the execution authority.
export const PluginUpdateReview = Schema.Struct({
  version: Schema.String,
  setupCommands: Schema.Array(Schema.String),
  runCommand: Schema.String,
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  requirements: Schema.optional(PluginRequirements)
})
export type PluginUpdateReview = typeof PluginUpdateReview.Type

export const PluginNamedChanges = Schema.Struct({
  added: Schema.Array(Schema.String),
  removed: Schema.Array(Schema.String),
  changed: Schema.Array(Schema.String)
})
export type PluginNamedChanges = typeof PluginNamedChanges.Type

export const PluginUpdatePlan = Schema.Struct({
  planId: Schema.String,
  pluginId: Schema.String,
  name: Schema.String,
  resolvedCommit: Schema.String,
  expiresAt: Schema.String,
  current: PluginUpdateReview,
  candidate: PluginUpdateReview,
  paneChanges: PluginNamedChanges,
  toolChanges: PluginNamedChanges
})
export type PluginUpdatePlan = typeof PluginUpdatePlan.Type

export const ApplyPluginUpdateRequest = Schema.Struct({
  planId: Schema.String
})
export type ApplyPluginUpdateRequest = typeof ApplyPluginUpdateRequest.Type

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
