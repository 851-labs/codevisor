import { Schema } from "effect"

export const SandboxProviderKind = Schema.Literals([
  "tart",
  "tart-orchard",
  "e2b",
  "modal",
  "vercel",
  "daytona"
])
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
  "failed",
  "archived"
])
export type SandboxState = typeof SandboxState.Type

export const SandboxSetupStage = Schema.Literals([
  "tart",
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
  projectName: Schema.optional(Schema.String),
  repoUrl: Schema.optional(Schema.String),
  profileId: Schema.optional(Schema.String),
  profileName: Schema.optional(Schema.String),
  accountId: Schema.optional(Schema.String),
  state: SandboxState,
  createdAt: Schema.String,
  providerMachineId: Schema.optional(Schema.String),
  platform: Schema.optional(Schema.Literals(["linux", "darwin"])),
  expiresAt: Schema.optional(Schema.String),
  deviceId: Schema.optional(Schema.String),
  machineId: Schema.optional(Schema.String),
  remoteProjectId: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  workspaceName: Schema.optional(Schema.String),
  restoresWorkspace: Schema.optional(Schema.Boolean),
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
  profileId: Schema.String,
  projectId: Schema.String,
  projectName: Schema.optional(Schema.String),
  repoUrl: Schema.optional(Schema.String),
  name: Schema.optional(Schema.String),
  workspaceId: Schema.optional(Schema.String),
  defersWorkspace: Schema.optional(Schema.Boolean),
  harnessId: Schema.optional(Schema.String)
})
export type CreateSandboxRequest = typeof CreateSandboxRequest.Type

export const ClaimSandboxWorkspaceRequest = Schema.Struct({ workspaceId: Schema.String })
export type ClaimSandboxWorkspaceRequest = typeof ClaimSandboxWorkspaceRequest.Type

export const SandboxFieldValue = Schema.Union([Schema.String, Schema.Number, Schema.Boolean])
export type SandboxFieldValue = typeof SandboxFieldValue.Type

export const SandboxFieldValues = Schema.Record(Schema.String, SandboxFieldValue)
export type SandboxFieldValues = typeof SandboxFieldValues.Type

export const SandboxField = Schema.Struct({
  key: Schema.String,
  label: Schema.String,
  type: Schema.Literals(["string", "secret", "url", "number", "boolean", "choice", "machine"]),
  required: Schema.Boolean,
  default: Schema.optional(SandboxFieldValue),
  choices: Schema.optional(
    Schema.Array(Schema.Struct({ value: Schema.String, label: Schema.String }))
  ),
  placeholder: Schema.optional(Schema.String),
  help: Schema.optional(Schema.String),
  min: Schema.optional(Schema.Number),
  max: Schema.optional(Schema.Number),
  steps: Schema.optional(Schema.Array(Schema.Number)),
  fallbackMax: Schema.optional(Schema.Number),
  unit: Schema.optional(Schema.String),
  capability: Schema.optional(Schema.String)
})
export type SandboxField = typeof SandboxField.Type

export const SandboxProviderInfo = Schema.Struct({
  id: SandboxProviderKind,
  displayName: Schema.String,
  sandboxNoun: Schema.String,
  platform: Schema.Literals(["linux", "darwin"]),
  tested: Schema.Boolean,
  accountFields: Schema.Array(SandboxField),
  profileFields: Schema.Array(SandboxField)
})
export type SandboxProviderInfo = typeof SandboxProviderInfo.Type

export const SandboxProvidersResponse = Schema.Struct({
  providers: Schema.Array(SandboxProviderInfo),
  capabilities: Schema.Array(Schema.String),
  maximums: Schema.Record(Schema.String, Schema.Record(Schema.String, Schema.Number))
})
export type SandboxProvidersResponse = typeof SandboxProvidersResponse.Type

export const SandboxAccount = Schema.Struct({
  id: Schema.String,
  provider: SandboxProviderKind,
  label: Schema.optional(Schema.String),
  identity: Schema.optional(Schema.String),
  values: SandboxFieldValues,
  secretsSet: Schema.Array(Schema.String),
  createdAt: Schema.String
})
export type SandboxAccount = typeof SandboxAccount.Type

export const SandboxAccountsResponse = Schema.Struct({ accounts: Schema.Array(SandboxAccount) })
export type SandboxAccountsResponse = typeof SandboxAccountsResponse.Type

export const SaveSandboxAccountRequest = Schema.Struct({
  provider: SandboxProviderKind,
  label: Schema.optional(Schema.String),
  values: Schema.Record(Schema.String, Schema.Unknown)
})
export type SaveSandboxAccountRequest = typeof SaveSandboxAccountRequest.Type

export const SandboxProfile = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  provider: SandboxProviderKind,
  accountId: Schema.optional(Schema.String),
  values: SandboxFieldValues,
  createdAt: Schema.String
})
export type SandboxProfile = typeof SandboxProfile.Type

export const SandboxProfilesResponse = Schema.Struct({ profiles: Schema.Array(SandboxProfile) })
export type SandboxProfilesResponse = typeof SandboxProfilesResponse.Type

export const SaveSandboxProfileRequest = Schema.Struct({
  name: Schema.String,
  provider: SandboxProviderKind,
  accountId: Schema.optional(Schema.String),
  values: Schema.Record(Schema.String, Schema.Unknown)
})
export type SaveSandboxProfileRequest = typeof SaveSandboxProfileRequest.Type

export const SandboxProfileAvailability = Schema.Struct({
  profileId: Schema.String,
  disabledReason: Schema.optional(Schema.String)
})
export type SandboxProfileAvailability = typeof SandboxProfileAvailability.Type

export const SandboxAvailabilityResponse = Schema.Struct({
  profiles: Schema.Array(SandboxProfileAvailability)
})
export type SandboxAvailabilityResponse = typeof SandboxAvailabilityResponse.Type

export const SANDBOXES_FEATURE_FLAG = {
  namespace: "client-preferences",
  key: "featureFlags.sandboxes"
} as const

interface FeatureFlagEntry {
  readonly key: string
  readonly value: unknown
  readonly deleted?: boolean | undefined
}

export const sandboxesFlagOn = (entries: ReadonlyArray<FeatureFlagEntry>): boolean =>
  entries.some(
    (entry) =>
      entry.key === SANDBOXES_FEATURE_FLAG.key && entry.deleted !== true && entry.value === true
  )
