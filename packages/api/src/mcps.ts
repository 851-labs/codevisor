import { Schema } from "effect"

export const McpTransport = Schema.Literals(["http", "stdio"])
export type McpTransport = typeof McpTransport.Type

export const McpServerKind = Schema.Literals(["managed", "browserUse", "computerUse"])
export type McpServerKind = typeof McpServerKind.Type

export const McpAuthType = Schema.Literals(["none", "bearer", "oauth"])
export type McpAuthType = typeof McpAuthType.Type

export const DetectMcpAuthRequest = Schema.Struct({ url: Schema.String })
export type DetectMcpAuthRequest = typeof DetectMcpAuthRequest.Type

export const McpAuthDetection = Schema.Struct({
  authType: McpAuthType,
  detail: Schema.String,
  suggestedName: Schema.optional(Schema.String)
})
export type McpAuthDetection = typeof McpAuthDetection.Type

export const McpConnectionState = Schema.Literals([
  "disconnected",
  "connecting",
  "connected",
  "needsSetup",
  "unavailable",
  "needsAuthorization",
  "expired",
  "error"
])
export type McpConnectionState = typeof McpConnectionState.Type

export const BrowserPreference = Schema.Literals(["chrome", "managed"])
export type BrowserPreference = typeof BrowserPreference.Type

export const BrowserUseConfiguration = Schema.Struct({
  preferredBrowser: Schema.optional(BrowserPreference),
  chromeAvailable: Schema.Boolean,
  chromeConnected: Schema.Boolean,
  managedAvailable: Schema.Boolean,
  // False on remote-kind servers: no desktop user is at that machine, so the
  // Chrome-extension flow is disabled and setup auto-selects the managed
  // browser. Optional for servers that predate the field (treat as true).
  extensionFlowSupported: Schema.optional(Schema.Boolean),
  developmentExtensionPath: Schema.optional(Schema.String)
})
export type BrowserUseConfiguration = typeof BrowserUseConfiguration.Type

export const UpdateBrowserUseConfigurationRequest = Schema.Struct({
  preferredBrowser: Schema.NullOr(BrowserPreference)
})
export type UpdateBrowserUseConfigurationRequest = typeof UpdateBrowserUseConfigurationRequest.Type

export const McpServer = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: McpServerKind,
  canEdit: Schema.Boolean,
  canRemove: Schema.Boolean,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.Array(Schema.String),
  headerNames: Schema.optional(Schema.Array(Schema.String)),
  environmentNames: Schema.optional(Schema.Array(Schema.String)),
  enabled: Schema.Boolean,
  authType: McpAuthType,
  oauthScope: Schema.optional(Schema.String),
  connectionState: McpConnectionState,
  toolCount: Schema.Number,
  detail: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.String
})
export type McpServer = typeof McpServer.Type

export const McpTool = Schema.Struct({
  serverId: Schema.String,
  serverName: Schema.String,
  name: Schema.String,
  title: Schema.optional(Schema.String),
  description: Schema.optional(Schema.String),
  inputSchema: Schema.Unknown
})
export type McpTool = typeof McpTool.Type

export const CreateMcpServerRequest = Schema.Struct({
  name: Schema.String,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
  env: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  headers: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  enabled: Schema.optional(Schema.Boolean),
  authType: Schema.optional(McpAuthType),
  bearerToken: Schema.optional(Schema.String),
  oauthScope: Schema.optional(Schema.String),
  oauthClientId: Schema.optional(Schema.String),
  oauthClientSecret: Schema.optional(Schema.String)
})
export type CreateMcpServerRequest = typeof CreateMcpServerRequest.Type

export const UpdateMcpServerRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  enabled: Schema.optional(Schema.Boolean),
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
  env: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  headers: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  removeEnv: Schema.optional(Schema.Array(Schema.String)),
  removeHeaders: Schema.optional(Schema.Array(Schema.String)),
  authType: Schema.optional(McpAuthType),
  bearerToken: Schema.optional(Schema.String),
  oauthScope: Schema.optional(Schema.String),
  oauthClientId: Schema.optional(Schema.String),
  oauthClientSecret: Schema.optional(Schema.String)
})
export type UpdateMcpServerRequest = typeof UpdateMcpServerRequest.Type

export const McpOAuthStartResponse = Schema.Struct({
  authorizationUrl: Schema.String
})
export type McpOAuthStartResponse = typeof McpOAuthStartResponse.Type

/// An MCP server registered directly in a harness's own config file (not
/// managed by Codevisor). Secret values never leave the server — only the
/// env/header names are exposed for display.
export const NativeMcpServer = Schema.Struct({
  harnessId: Schema.String,
  harnessName: Schema.String,
  serverName: Schema.String,
  /// "global" = the harness's user-level config; "project" = a committed
  /// project file (.mcp.json) — always read-only in Codevisor.
  scope: Schema.Literals(["global", "project"]),
  configPath: Schema.String,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.Array(Schema.String),
  envNames: Schema.Array(Schema.String),
  headerNames: Schema.Array(Schema.String),
  /// Present only when the harness has a real per-server enable flag.
  enabled: Schema.optional(Schema.Boolean),
  supportsDisable: Schema.Boolean,
  supportsRemove: Schema.Boolean,
  /// Cross-harness identity (normalized URL, package name, or command line)
  /// used to coalesce duplicates and match managed servers.
  identity: Schema.String,
  alreadyManaged: Schema.Boolean
})
export type NativeMcpServer = typeof NativeMcpServer.Type

/// One importable server, coalesced across every harness it was found in.
export const NativeMcpImportCandidate = Schema.Struct({
  identity: Schema.String,
  name: Schema.String,
  transport: McpTransport,
  url: Schema.optional(Schema.String),
  command: Schema.optional(Schema.String),
  args: Schema.Array(Schema.String),
  /// Harness ids this server was discovered in (display: "Found in …").
  foundIn: Schema.Array(Schema.String),
  alreadyManaged: Schema.Boolean
})
export type NativeMcpImportCandidate = typeof NativeMcpImportCandidate.Type

export const NativeMcpHarnessServers = Schema.Struct({
  harnessId: Schema.String,
  harnessName: Schema.String,
  /// SF Symbol name from the harness catalog, for section icons.
  harnessSymbol: Schema.String,
  configPath: Schema.String,
  exists: Schema.Boolean,
  /// Per-harness read/parse failure, surfaced instead of failing the scan.
  error: Schema.optional(Schema.String),
  servers: Schema.Array(NativeMcpServer)
})
export type NativeMcpHarnessServers = typeof NativeMcpHarnessServers.Type

export const NativeMcpScan = Schema.Struct({
  candidates: Schema.Array(NativeMcpImportCandidate),
  harnesses: Schema.Array(NativeMcpHarnessServers)
})
export type NativeMcpScan = typeof NativeMcpScan.Type

/// Import coalesced candidates (by identity) into Codevisor's managed MCP
/// servers. Secret values are re-read from the native configs server-side —
/// they never travel through the client.
export const ImportNativeMcpsRequest = Schema.Struct({
  identities: Schema.Array(Schema.String)
})
export type ImportNativeMcpsRequest = typeof ImportNativeMcpsRequest.Type

export const NativeMcpImportOutcome = Schema.Struct({
  identity: Schema.String,
  status: Schema.Literals(["imported", "skipped", "failed"]),
  /// The created managed server, present when status is "imported".
  serverId: Schema.optional(Schema.String),
  serverName: Schema.optional(Schema.String),
  /// Why the item was skipped or failed.
  detail: Schema.optional(Schema.String),
  /// Non-fatal caveats: ${VAR} placeholder secrets imported verbatim,
  /// authorization probe unreachable, etc.
  warnings: Schema.Array(Schema.String)
})
export type NativeMcpImportOutcome = typeof NativeMcpImportOutcome.Type

export const ImportNativeMcpsResult = Schema.Struct({
  outcomes: Schema.Array(NativeMcpImportOutcome),
  /// Post-import rescan so clients can replace their state wholesale.
  scan: NativeMcpScan
})
export type ImportNativeMcpsResult = typeof ImportNativeMcpsResult.Type

/// A server entry Codevisor removed from a harness config file, parked
/// verbatim so the removal can be undone.
export const NativeMcpRemoval = Schema.Struct({
  id: Schema.String,
  harnessId: Schema.String,
  configPath: Schema.String,
  serverName: Schema.String,
  removedAt: Schema.String,
  restoredAt: Schema.optional(Schema.String)
})
export type NativeMcpRemoval = typeof NativeMcpRemoval.Type

export const RemoveNativeMcpRequest = Schema.Struct({
  harnessId: Schema.String,
  serverName: Schema.String
})
export type RemoveNativeMcpRequest = typeof RemoveNativeMcpRequest.Type

export const RemoveNativeMcpResult = Schema.Struct({
  removal: NativeMcpRemoval,
  scan: NativeMcpScan
})
export type RemoveNativeMcpResult = typeof RemoveNativeMcpResult.Type

export const SetNativeMcpEnabledRequest = Schema.Struct({
  harnessId: Schema.String,
  serverName: Schema.String,
  enabled: Schema.Boolean
})
export type SetNativeMcpEnabledRequest = typeof SetNativeMcpEnabledRequest.Type
