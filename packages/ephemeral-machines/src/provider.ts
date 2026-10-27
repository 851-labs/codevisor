import type { Schema } from "effect"

export const EPHEMERAL_PROVIDER_IDS = ["e2b", "modal", "tart"] as const
export type EphemeralProviderId = (typeof EPHEMERAL_PROVIDER_IDS)[number]

export type MachinePlatform = "linux" | "darwin"

export interface EphemeralTags {
  readonly owner: string
  readonly machine: string
}

export interface CreateSpec {
  readonly name: string
  readonly tags: EphemeralTags
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
  readonly tags: EphemeralTags
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

export interface EphemeralProvider<Options = unknown> {
  readonly id: EphemeralProviderId
  readonly displayName: string
  readonly options: Schema.Codec<Options, unknown>
  readonly provisionStages: ReadonlyArray<ProvisionStage>
  readonly streamsOutput: boolean
  plan?(options: Options): Promise<ProvisionPlan>
  prepare?(options: Options, plan: ProvisionPlan, progress: ProvisionProgress): Promise<Options>
  create(spec: CreateSpec, options: Options, progress?: ProvisionProgress): Promise<CreatedMachine>
  readonly exec: (providerMachineId: string, request: ExecRequest) => Promise<ExecResult>
  readonly status: (providerMachineId: string) => Promise<ProviderMachineStatus>
  readonly destroy: (providerMachineId: string) => Promise<void>
  readonly list: (owner: string) => Promise<ReadonlyArray<ListedMachine>>
  readonly resume?: (providerMachineId: string) => Promise<void>
  readonly gui?: (providerMachineId: string) => Promise<GuiEndpoint>
  readonly snapshot?: (providerMachineId: string) => Promise<SnapshotRef>
}

export class EphemeralProviderError extends Error {
  override readonly name = "EphemeralProviderError"

  constructor(
    readonly provider: EphemeralProviderId,
    message: string
  ) {
    super(message)
  }
}

export const isEphemeralProviderId = (value: unknown): value is EphemeralProviderId =>
  typeof value === "string" && (EPHEMERAL_PROVIDER_IDS as ReadonlyArray<string>).includes(value)
