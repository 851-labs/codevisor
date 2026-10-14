import { Schema } from "effect"

export const SUPPORTED_PLUGIN_PROTOCOL_VERSIONS = [1, 2] as const

export const isSupportedPluginProtocolVersion = (version: number): boolean =>
  SUPPORTED_PLUGIN_PROTOCOL_VERSIONS.some((supported) => supported === version)

export const PluginPaneDescriptor = Schema.Struct({
  type: Schema.String,
  title: Schema.String,
  path: Schema.String,
  iconPath: Schema.optional(Schema.String)
})
export type PluginPaneDescriptor = typeof PluginPaneDescriptor.Type

export const PluginCommand = Schema.Struct({
  command: Schema.String
})
export type PluginCommand = typeof PluginCommand.Type

export const PluginArgvCommand = Schema.Struct({
  argv: Schema.Array(Schema.String)
})
export type PluginArgvCommand = typeof PluginArgvCommand.Type

export const PluginSetupStep = Schema.Struct({
  argv: Schema.Array(Schema.String),
  platforms: Schema.optional(Schema.Array(Schema.String))
})
export type PluginSetupStep = typeof PluginSetupStep.Type

export const PluginExecutableRequirement = Schema.Struct({
  name: Schema.String,
  installHint: Schema.optional(Schema.String),
  helpUrl: Schema.optional(Schema.String)
})
export type PluginExecutableRequirement = typeof PluginExecutableRequirement.Type

export const PluginRequirements = Schema.Struct({
  executables: Schema.optional(Schema.Array(PluginExecutableRequirement))
})
export type PluginRequirements = typeof PluginRequirements.Type

export const PluginToolDescriptor = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  path: Schema.String,
  inputSchema: Schema.optional(Schema.Unknown)
})
export type PluginToolDescriptor = typeof PluginToolDescriptor.Type

const PluginManifestBase = {
  ageRating: Schema.optional(Schema.Literals([4, 9, 13, 16, 18])),
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  platforms: Schema.optional(Schema.Array(Schema.String)),
  healthPath: Schema.optional(Schema.String)
}

export const PluginManifestV1 = Schema.Struct({
  ...PluginManifestBase,
  protocolVersion: Schema.Literal(1),
  install: Schema.optional(PluginCommand),
  run: PluginCommand
})
export type PluginManifestV1 = typeof PluginManifestV1.Type

export const PluginManifestV2 = Schema.Struct({
  ...PluginManifestBase,
  protocolVersion: Schema.Literal(2),
  setup: Schema.optional(Schema.Array(PluginSetupStep)),
  run: PluginArgvCommand,
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements)
})
export type PluginManifestV2 = typeof PluginManifestV2.Type

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

export const PluginSource = Schema.Literals(["managed", "linked"])
export type PluginSource = typeof PluginSource.Type

export const PluginSummary = Schema.Struct({
  ageRating: Schema.optional(Schema.Number),
  consentKey: Schema.optional(Schema.String),
  sourceRepo: Schema.optional(Schema.String),
  enabled: Schema.Boolean,
  canRestore: Schema.Boolean,
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  source: PluginSource,
  path: Schema.String,
  state: PluginRuntimeState,
  openPaneCount: Schema.optional(Schema.Number)
})
export type PluginSummary = typeof PluginSummary.Type

export const PluginListResponse = Schema.Struct({
  plugins: Schema.Array(PluginSummary)
})
export type PluginListResponse = typeof PluginListResponse.Type

export const SetPluginEnabledRequest = Schema.Struct({
  enabled: Schema.Boolean
})
export type SetPluginEnabledRequest = typeof SetPluginEnabledRequest.Type

export const PluginPaneTokenRequest = Schema.Struct({
  paneType: Schema.String,
  workspaceId: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String),
  themeMode: Schema.optional(Schema.String)
})
export type PluginPaneTokenRequest = typeof PluginPaneTokenRequest.Type

export const PluginPaneTokenResponse = Schema.Struct({
  token: Schema.String,
  path: Schema.String,
  url: Schema.optional(Schema.String),
  expiresAt: Schema.String
})
export type PluginPaneTokenResponse = typeof PluginPaneTokenResponse.Type

export const DiscoverRemotePluginRequest = Schema.Struct({
  source: Schema.String
})
export type DiscoverRemotePluginRequest = typeof DiscoverRemotePluginRequest.Type

export const DiscoverRemotePluginResult = Schema.Struct({
  ageRating: Schema.optional(Schema.Number),
  consentKey: Schema.optional(Schema.String),
  sourceRepo: Schema.optional(Schema.String),
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  description: Schema.optional(Schema.String),
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  installCommand: Schema.optional(Schema.String),
  setupCommands: Schema.optional(Schema.Array(PluginSetupStep)),
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements),
  runCommand: Schema.String,
  alreadyInstalled: Schema.Boolean
})
export type DiscoverRemotePluginResult = typeof DiscoverRemotePluginResult.Type

export const ImportRemotePluginRequest = Schema.Struct({
  source: Schema.String
})
export type ImportRemotePluginRequest = typeof ImportRemotePluginRequest.Type

export const LinkPluginRequest = Schema.Struct({
  path: Schema.String
})
export type LinkPluginRequest = typeof LinkPluginRequest.Type

export const PluginRegistryEntry = Schema.Struct({
  ageRating: Schema.optional(Schema.Number),
  id: Schema.String,
  name: Schema.String,
  version: Schema.String,
  protocolVersion: Schema.Number,
  description: Schema.optional(Schema.String),
  iconPath: Schema.optional(Schema.String),
  panes: Schema.Array(PluginPaneDescriptor),
  tools: Schema.optional(Schema.Array(PluginToolDescriptor)),
  repo: Schema.String,
  commit: Schema.String,
  minCodevisorVersion: Schema.optional(Schema.String),
  requirements: Schema.optional(PluginRequirements),
  platforms: Schema.optional(Schema.Array(Schema.String)),
  ownerAvatarUrl: Schema.optional(Schema.String),
  stars: Schema.Number,
  pushedAt: Schema.String,
  verified: Schema.optional(Schema.Boolean)
})
export type PluginRegistryEntry = typeof PluginRegistryEntry.Type

export const PluginRegistryRejection = Schema.Struct({
  repo: Schema.String,
  reason: Schema.String
})
export type PluginRegistryRejection = typeof PluginRegistryRejection.Type

export const PluginRegistryIndex = Schema.Struct({
  generatedAt: Schema.NullOr(Schema.String),
  entries: Schema.Array(PluginRegistryEntry),
  rejected: Schema.Array(PluginRegistryRejection)
})
export type PluginRegistryIndex = typeof PluginRegistryIndex.Type

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
  reason: Schema.optional(Schema.String)
})
export type PluginUpdateStatus = typeof PluginUpdateStatus.Type

export const PluginUpdatesResponse = Schema.Struct({
  updates: Schema.Array(PluginUpdateStatus)
})
export type PluginUpdatesResponse = typeof PluginUpdatesResponse.Type

export const PluginUpdateReview = Schema.Struct({
  ageRating: Schema.optional(Schema.Number),
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

export const InvokePluginToolRequest = Schema.Struct({
  args: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
  workspaceId: Schema.optional(Schema.String),
  cwd: Schema.optional(Schema.String)
})
export type InvokePluginToolRequest = typeof InvokePluginToolRequest.Type
