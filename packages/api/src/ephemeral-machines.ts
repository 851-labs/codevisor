import { Schema } from "effect"

export const EphemeralProviderKind = Schema.Literals(["e2b", "modal", "tart"])
export type EphemeralProviderKind = typeof EphemeralProviderKind.Type

export const EphemeralMachineOrigin = Schema.Struct({
  provider: Schema.String,
  ownerDeviceId: Schema.String
})
export type EphemeralMachineOrigin = typeof EphemeralMachineOrigin.Type

export const EphemeralMachineState = Schema.Literals([
  "creating",
  "bootstrapping",
  "syncing",
  "cloning",
  "ready",
  "destroying",
  "failed"
])
export type EphemeralMachineState = typeof EphemeralMachineState.Type

export const EphemeralMachine = Schema.Struct({
  id: Schema.String,
  provider: EphemeralProviderKind,
  name: Schema.String,
  projectId: Schema.String,
  state: EphemeralMachineState,
  createdAt: Schema.String,
  providerMachineId: Schema.optional(Schema.String),
  platform: Schema.optional(Schema.Literals(["linux", "darwin"])),
  expiresAt: Schema.optional(Schema.String),
  deviceId: Schema.optional(Schema.String),
  machineId: Schema.optional(Schema.String),
  remoteProjectId: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  workspaceOpenedAt: Schema.optional(Schema.String),
  error: Schema.optional(Schema.String)
})
export type EphemeralMachine = typeof EphemeralMachine.Type

export const EphemeralMachinesResponse = Schema.Array(EphemeralMachine)
export type EphemeralMachinesResponse = typeof EphemeralMachinesResponse.Type

export const DestroyEphemeralMachineResponse = Schema.Struct({ destroyed: Schema.String })
export type DestroyEphemeralMachineResponse = typeof DestroyEphemeralMachineResponse.Type

export const CreateEphemeralMachineRequest = Schema.Struct({
  provider: EphemeralProviderKind,
  projectId: Schema.String,
  name: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  options: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})
export type CreateEphemeralMachineRequest = typeof CreateEphemeralMachineRequest.Type

export const EphemeralProviderSummary = Schema.Struct({
  id: EphemeralProviderKind,
  displayName: Schema.String,
  configured: Schema.Boolean,
  credentialKeys: Schema.Array(Schema.String),
  defaults: Schema.Record(Schema.String, Schema.Unknown)
})
export type EphemeralProviderSummary = typeof EphemeralProviderSummary.Type

export const EphemeralProvidersResponse = Schema.Struct({
  providers: Schema.Array(EphemeralProviderSummary)
})
export type EphemeralProvidersResponse = typeof EphemeralProvidersResponse.Type

export const SaveEphemeralCredentialsRequest = Schema.Struct({
  values: Schema.Record(Schema.String, Schema.String)
})
export type SaveEphemeralCredentialsRequest = typeof SaveEphemeralCredentialsRequest.Type

export const EphemeralProjectOptions = Schema.Record(
  Schema.String,
  Schema.Record(Schema.String, Schema.Unknown)
)
export type EphemeralProjectOptions = typeof EphemeralProjectOptions.Type

export const EphemeralProjectOptionsResponse = Schema.Struct({
  projectId: Schema.String,
  options: EphemeralProjectOptions
})
export type EphemeralProjectOptionsResponse = typeof EphemeralProjectOptionsResponse.Type
