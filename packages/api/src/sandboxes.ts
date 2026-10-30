import { Schema } from "effect"

import { Labels } from "./labels.js"
import { SyncEntry } from "./sync.js"

export const SandboxProviderKind = Schema.Literals([
  "tart",
  "tart-orchard",
  "apple-container",
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

export const SandboxPower = Schema.Literals(["paused", "waking"])
export type SandboxPower = typeof SandboxPower.Type

export const SandboxSetupStage = Schema.Literals([
  "tart",
  "container",
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

export const SandboxSetupLogResponse = Schema.Struct({ lines: Schema.Array(SandboxSetupLog) })
export type SandboxSetupLogResponse = typeof SandboxSetupLogResponse.Type

export const SandboxAgentStart = Schema.Struct({
  prompt: Schema.String,
  title: Schema.String,
  harness: Schema.String,
  model: Schema.optional(Schema.String),
  labels: Schema.optional(Labels),
  parentSessionId: Schema.optional(Schema.String)
})
export type SandboxAgentStart = typeof SandboxAgentStart.Type

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
  createdOn: Schema.optional(Schema.String),
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
  placeholderPending: Schema.optional(Schema.Boolean),
  plan: Schema.optional(Schema.Array(SandboxSetupStage)),
  steps: Schema.optional(Schema.Array(SandboxSetupStep)),
  harnessId: Schema.optional(Schema.String),
  agent: Schema.optional(SandboxAgentStart),
  agentId: Schema.optional(Schema.String),
  power: Schema.optional(SandboxPower),
  lastActiveAt: Schema.optional(Schema.String),
  pausedSnapshot: Schema.optional(Schema.String),
  error: Schema.optional(Schema.String)
})
export type Sandbox = typeof Sandbox.Type

export const SandboxesResponse = Schema.Array(Sandbox)
export type SandboxesResponse = typeof SandboxesResponse.Type

export const DEFAULT_SANDBOX_WAIT_TIMEOUT_MS = 60_000
export const MAX_SANDBOX_WAIT_TIMEOUT_MS = 300_000

export const WaitForSandboxRequest = Schema.Struct({ timeoutMs: Schema.optional(Schema.Number) })
export type WaitForSandboxRequest = typeof WaitForSandboxRequest.Type

export const WaitForSandboxResponse = Schema.Struct({
  ...Sandbox.fields,
  timedOut: Schema.Boolean
})
export type WaitForSandboxResponse = typeof WaitForSandboxResponse.Type

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
  harnessId: Schema.optional(Schema.String),
  agent: Schema.optional(SandboxAgentStart)
})
export type CreateSandboxRequest = typeof CreateSandboxRequest.Type

export const ClaimSandboxWorkspaceRequest = Schema.Struct({ workspaceId: Schema.String })
export type ClaimSandboxWorkspaceRequest = typeof ClaimSandboxWorkspaceRequest.Type

export const ChooseSandboxHarnessRequest = Schema.Struct({ harnessId: Schema.String })
export type ChooseSandboxHarnessRequest = typeof ChooseSandboxHarnessRequest.Type

export const SANDBOX_MANAGER_ROLE = "sandbox-manager"
export const FLEET_SANDBOX_ACTION_PATH = "fleet.sandbox_action"

export const FleetSandboxAction = Schema.Union([
  Schema.Struct({ action: Schema.Literal("destroy"), id: Schema.String }),
  Schema.Struct({ action: Schema.Literal("wake"), id: Schema.String }),
  Schema.Struct({
    action: Schema.Literal("claim-workspace"),
    id: Schema.String,
    workspaceId: Schema.String
  })
])
export type FleetSandboxAction = typeof FleetSandboxAction.Type

export const FleetSandboxRequest = Schema.Struct({
  request: FleetSandboxAction,
  record: SyncEntry
})
export type FleetSandboxRequest = typeof FleetSandboxRequest.Type

export const FleetSandboxAnswer = Schema.Struct({
  sandbox: Schema.optional(Sandbox),
  record: SyncEntry
})
export type FleetSandboxAnswer = typeof FleetSandboxAnswer.Type

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
  description: Schema.optional(Schema.String),
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
  disabledReason: Schema.optional(Schema.String),
  full: Schema.optional(Schema.Boolean)
})
export type SandboxProfileAvailability = typeof SandboxProfileAvailability.Type

export const SandboxAvailabilityResponse = Schema.Struct({
  profiles: Schema.Array(SandboxProfileAvailability)
})
export type SandboxAvailabilityResponse = typeof SandboxAvailabilityResponse.Type
