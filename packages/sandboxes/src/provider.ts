import type { SandboxField, SandboxFieldValues } from "./fields.js"

export const SANDBOX_PROVIDER_IDS = [
  "tart",
  "tart-orchard",
  "e2b",
  "modal",
  "vercel",
  "daytona"
] as const
export type SandboxProviderId = (typeof SANDBOX_PROVIDER_IDS)[number]

export type MachinePlatform = "linux" | "darwin"

export interface SandboxTags {
  readonly owner: string
  readonly machine: string
}

export interface CreateSpec {
  readonly name: string
  readonly tags: SandboxTags
}

export interface CreatedMachine {
  readonly providerMachineId: string
  readonly platform: MachinePlatform
  readonly expiresAt?: string
  readonly preinstalled?: boolean
}

export type ProviderMachineState = "starting" | "running" | "stopped" | "gone"

export interface ProviderMachineStatus {
  readonly state: ProviderMachineState
  readonly expiresAt?: string
}

export interface ListedMachine {
  readonly providerMachineId: string
  readonly tags: SandboxTags
}

export type OutputStream = "stdout" | "stderr"

export interface ExecRequest {
  readonly script: string
  readonly stdin?: string
  readonly timeoutMs?: number
  readonly onOutput?: (stream: OutputStream, text: string) => void
}

export type ProvisionStage = "image" | "create" | "boot"

export interface ProvisionProgress {
  readonly stage: (stage: ProvisionStage) => void
  readonly log: (line: string) => void
  readonly output: (stream: OutputStream, text: string) => void
}

export interface ProvisionPlan {
  readonly stages: ReadonlyArray<ProvisionStage>
  readonly preinstalled: boolean
}

export interface ExecResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

export interface GuiEndpoint {
  readonly vncUrl: string
}

export interface SnapshotRef {
  readonly snapshotId: string
}

export interface SandboxProviderDefinition {
  readonly id: SandboxProviderId
  readonly displayName: string
  readonly sandboxNoun: string
  readonly platform: MachinePlatform
  readonly tested: boolean
  readonly accountFields: ReadonlyArray<SandboxField>
  readonly profileFields: ReadonlyArray<SandboxField>
}

export interface SandboxAccountIdentity {
  readonly identity?: string
}

export interface SandboxProvider {
  readonly definition: SandboxProviderDefinition
  readonly provisionStages: ReadonlyArray<ProvisionStage>
  readonly streamsOutput: boolean
  availability?(options: SandboxFieldValues): Promise<string | undefined>
  plan?(options: SandboxFieldValues): Promise<ProvisionPlan>
  prepare?(
    options: SandboxFieldValues,
    plan: ProvisionPlan,
    progress: ProvisionProgress
  ): Promise<SandboxFieldValues>
  create(
    spec: CreateSpec,
    options: SandboxFieldValues,
    progress?: ProvisionProgress
  ): Promise<CreatedMachine>
  readonly exec: (providerMachineId: string, request: ExecRequest) => Promise<ExecResult>
  readonly status: (providerMachineId: string) => Promise<ProviderMachineStatus>
  readonly destroy: (providerMachineId: string) => Promise<void>
  readonly list: (owner: string) => Promise<ReadonlyArray<ListedMachine>>
  readonly resume?: (providerMachineId: string) => Promise<void>
  readonly gui?: (providerMachineId: string) => Promise<GuiEndpoint>
  readonly snapshot?: (providerMachineId: string) => Promise<SnapshotRef>
}

export interface SandboxAdapter {
  readonly definition: SandboxProviderDefinition
  readonly connect: (account: SandboxFieldValues) => SandboxProvider
  readonly verify?: (account: SandboxFieldValues) => Promise<SandboxAccountIdentity>
}

export class SandboxProviderError extends Error {
  override readonly name = "SandboxProviderError"

  constructor(
    readonly provider: SandboxProviderId,
    message: string
  ) {
    super(message)
  }
}

export const isSandboxProviderId = (value: unknown): value is SandboxProviderId =>
  typeof value === "string" && (SANDBOX_PROVIDER_IDS as ReadonlyArray<string>).includes(value)
