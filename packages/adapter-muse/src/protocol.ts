import { randomBytes } from "node:crypto"

import { isPlainRecord } from "@codevisor/api"

export const TESTED_SCHEMA_FINGERPRINT =
  "sha256:6de32db08bbbe0deb478d2bfcaba001e9fb490986bc80db3aceb4d996abf7df9"

export const MINIMUM_MUSE_VERSION = "1.4.0"

export interface MuseSession {
  readonly sessionId: string
  readonly workspaceRoot: string | null
  readonly modelId: string | null
  readonly providerId: string | null
  readonly name?: string | undefined
  readonly title?: string | undefined
  readonly firstUserPrompt?: string | undefined
  readonly updatedAt: string
  readonly kind?: string | undefined
}

export interface PatchSummary {
  readonly files: number
  readonly added: number
  readonly removed: number
}

export interface MuseItem {
  readonly itemId: string
  readonly kind: string
  readonly status: string
  readonly revision: number
  readonly turnId?: string | null | undefined
  readonly text?: string | undefined
  readonly summary?: ReadonlyArray<string> | undefined
  readonly tool?: string | undefined
  readonly args?: string | undefined
  readonly visibleOutput?: string | undefined
  readonly patchSummary?: PatchSummary | undefined
  readonly failureReason?: string | undefined
  readonly childSessionId?: string | undefined
  readonly controlStatus?: string | undefined
  readonly objective?: string | undefined
  readonly role?: string | undefined
  readonly agentPath?: string | undefined
  readonly subagentId?: string | undefined
  readonly result?:
    | { readonly summary?: string | undefined; readonly text?: string | undefined }
    | undefined
  readonly selector?: string | undefined
  readonly query?: string | undefined
  readonly url?: string | undefined
}

export interface TokenUsage {
  readonly inputTokens?: number
  readonly outputTokens?: number
  readonly cachedTokens?: number
  readonly reasoningTokens?: number
  readonly cacheReadTokens?: number
}

export interface ApprovalChoice {
  readonly choiceId: string
  readonly label: string
  readonly decision: string
}

export interface ApprovalRequest {
  readonly approvalId: string
  readonly sessionId: string
  readonly toolName: string
  readonly toolCallId: string
  readonly rawArgs: string
  readonly availableChoices: ReadonlyArray<ApprovalChoice>
  readonly currentRequirementId: Readonly<Record<string, unknown>>
  readonly subject: {
    readonly kind: string
    readonly command?: string | undefined
    readonly path?: string | undefined
  }
}

export interface UserInputQuestion {
  readonly id: string
  readonly header: string
  readonly question: string
  readonly options: ReadonlyArray<{
    readonly label: string
    readonly description?: string | undefined
  }>
  readonly selection: { readonly mode: string }
}

export interface UserInputRequest {
  readonly userInputId: string
  readonly sessionId: string
  readonly questions: ReadonlyArray<UserInputQuestion>
  readonly autoResolutionMs?: number | undefined
}

export interface ModelCatalogEntry {
  readonly modelId: string
  readonly displayLabel: string
  readonly providerId: string
  readonly profileId: string | null
  readonly contextLimit: number | null
  readonly isActive: boolean
  readonly isDefault: boolean
  readonly defaultReasoningEffort?: string | undefined
  readonly variants?: ReadonlyArray<unknown> | undefined
  readonly reasoningEffortVariants?: ReadonlyArray<{ readonly tier: string }> | undefined
}

export interface AccountState {
  readonly state: string
  readonly credentialRequired: boolean
  readonly label?: string
}

export const record = (value: unknown): Record<string, unknown> =>
  isPlainRecord(value) ? value : {}

export const list = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

export const string = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

export const number = (value: unknown): number | undefined =>
  typeof value === "number" ? value : undefined

export const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export const commandId = (now: number = Date.now(), random: Buffer = randomBytes(16)): string => {
  const bytes = Buffer.from(random)
  bytes.writeUIntBE(now, 0, 6)
  bytes[6] = (bytes[6]! & 0x0f) | 0x70
  bytes[8] = (bytes[8]! & 0x3f) | 0x80
  const hex = bytes.toString("hex")
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

const releaseParts = (value: string): Array<number> =>
  value
    .split("-")[0]!
    .split(".")
    .map((part) => Number(part) || 0)

export const versionAtLeast = (version: string, minimum: string): boolean => {
  const have = releaseParts(version)
  const need = releaseParts(minimum)
  for (let index = 0; index < need.length; index += 1) {
    const difference = (have[index] ?? 0) - need[index]!
    if (difference !== 0) return difference > 0
  }
  return true
}
