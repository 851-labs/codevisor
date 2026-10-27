import { Schema } from "effect"

export const SandboxProviderKind = Schema.Literals(["e2b", "modal", "tart"])
export type SandboxProviderKind = typeof SandboxProviderKind.Type

export const SandboxOrigin = Schema.Struct({
  provider: Schema.String,
  ownerDeviceId: Schema.String
})
export type SandboxOrigin = typeof SandboxOrigin.Type

export const SandboxState = Schema.Literals([
  "creating",
  "bootstrapping",
  "syncing",
  "cloning",
  "ready",
  "destroying",
  "failed"
])
export type SandboxState = typeof SandboxState.Type

export const SandboxSetupStage = Schema.Literals([
  "image",
  "create",
  "boot",
  "install",
  "signIn",
  "sync",
  "clone"
])
export type SandboxSetupStage = typeof SandboxSetupStage.Type

export const SandboxSetupStep = Schema.Struct({
  stage: SandboxSetupStage,
  startedAt: Schema.String,
  endedAt: Schema.optional(Schema.String)
})
export type SandboxSetupStep = typeof SandboxSetupStep.Type

export const SandboxSetupLog = Schema.Struct({
  machineId: Schema.String,
  stage: SandboxSetupStage,
  stream: Schema.Literals(["stdout", "stderr"]),
  line: Schema.String
})
export type SandboxSetupLog = typeof SandboxSetupLog.Type

export const Sandbox = Schema.Struct({
  id: Schema.String,
  provider: SandboxProviderKind,
  name: Schema.String,
  projectId: Schema.String,
  state: SandboxState,
  createdAt: Schema.String,
  providerMachineId: Schema.optional(Schema.String),
  platform: Schema.optional(Schema.Literals(["linux", "darwin"])),
  expiresAt: Schema.optional(Schema.String),
  deviceId: Schema.optional(Schema.String),
  machineId: Schema.optional(Schema.String),
  remoteProjectId: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  defersWorkspace: Schema.optional(Schema.Boolean),
  workspaceOpenedAt: Schema.optional(Schema.String),
  plan: Schema.optional(Schema.Array(SandboxSetupStage)),
  steps: Schema.optional(Schema.Array(SandboxSetupStep)),
  error: Schema.optional(Schema.String)
})
export type Sandbox = typeof Sandbox.Type

export const SandboxesResponse = Schema.Array(Sandbox)
export type SandboxesResponse = typeof SandboxesResponse.Type

export const DestroySandboxResponse = Schema.Struct({ destroyed: Schema.String })
export type DestroySandboxResponse = typeof DestroySandboxResponse.Type

export const CreateSandboxRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  provider: SandboxProviderKind,
  projectId: Schema.String,
  name: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  defersWorkspace: Schema.optional(Schema.Boolean),
  harnessId: Schema.optional(Schema.String),
  options: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})
export type CreateSandboxRequest = typeof CreateSandboxRequest.Type

export const ClaimSandboxWorkspaceRequest = Schema.Struct({ workspaceId: Schema.String })
export type ClaimSandboxWorkspaceRequest = typeof ClaimSandboxWorkspaceRequest.Type

export const SandboxProviderSummary = Schema.Struct({
  id: SandboxProviderKind,
  displayName: Schema.String,
  configured: Schema.Boolean,
  credentialKeys: Schema.Array(Schema.String),
  defaults: Schema.Record(Schema.String, Schema.Unknown)
})
export type SandboxProviderSummary = typeof SandboxProviderSummary.Type

export const SandboxProvidersResponse = Schema.Struct({
  providers: Schema.Array(SandboxProviderSummary)
})
export type SandboxProvidersResponse = typeof SandboxProvidersResponse.Type

export const SaveSandboxCredentialsRequest = Schema.Struct({
  values: Schema.Record(Schema.String, Schema.String)
})
export type SaveSandboxCredentialsRequest = typeof SaveSandboxCredentialsRequest.Type

export const SandboxProjectOptions = Schema.Record(
  Schema.String,
  Schema.Record(Schema.String, Schema.Unknown)
)
export type SandboxProjectOptions = typeof SandboxProjectOptions.Type

export const SandboxProjectOptionsResponse = Schema.Struct({
  projectId: Schema.String,
  options: SandboxProjectOptions
})
export type SandboxProjectOptionsResponse = typeof SandboxProjectOptionsResponse.Type
