import { randomBytes } from "node:crypto"

/// The slice of the Muse Session Protocol (MSP) this adapter speaks. Shapes
/// follow `muse schema generate-ts --experimental` from Muse Code 1.4.7;
/// every server-produced vocabulary is open, so unknown values pass through.

/// The schema the adapter was verified against. A host reporting another
/// fingerprint still works (MSP evolves additively); it is only logged.
export const TESTED_SCHEMA_FINGERPRINT =
  "sha256:6de32db08bbbe0deb478d2bfcaba001e9fb490986bc80db3aceb4d996abf7df9"

/// The oldest Muse Code whose host serves everything a chat uses
/// (`skill/list`, `usage/read`, turn-level reasoning effort).
export const MINIMUM_MUSE_VERSION = "1.4.0"

export interface MuseSession {
  readonly sessionId: string
  readonly workspaceRoot: string | null
  readonly modelId: string | null
  readonly providerId: string | null
  readonly name?: string
  readonly title?: string
  readonly firstUserPrompt?: string
  readonly updatedAt: string
  readonly kind?: string
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
  readonly turnId?: string | null
  readonly text?: string
  readonly summary?: ReadonlyArray<string>
  readonly tool?: string
  readonly args?: string
  readonly visibleOutput?: string
  readonly patchSummary?: PatchSummary
  readonly patchRef?: { readonly id: string }
  readonly failureReason?: string
  readonly fallbackText?: string
  readonly childSessionId?: string
  readonly objective?: string
  readonly role?: string
  readonly result?: { readonly summary?: string; readonly text?: string }
  readonly selector?: string
  readonly query?: string
  readonly url?: string
  readonly outcome?: string
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
  readonly currentRequirementId: { readonly approvalId: string; readonly sourceIndex: number }
  readonly subject: { readonly kind: string; readonly command?: string; readonly path?: string }
}

export interface UserInputQuestion {
  readonly id: string
  readonly header: string
  readonly question: string
  readonly options: ReadonlyArray<{ readonly label: string; readonly description?: string }>
  readonly selection: { readonly mode: string }
}

export interface UserInputRequest {
  readonly userInputId: string
  readonly sessionId: string
  readonly questions: ReadonlyArray<UserInputQuestion>
  readonly autoResolutionMs?: number
}

export interface ModelCatalogEntry {
  readonly modelId: string
  readonly displayLabel: string
  readonly providerId: string
  readonly profileId: string | null
  readonly contextLimit: number | null
  readonly isActive: boolean
  readonly isDefault: boolean
  readonly defaultReasoningEffort?: string
  readonly variants?: ReadonlyArray<string> | Record<string, unknown>
  readonly reasoningEffortVariants?: ReadonlyArray<{ readonly tier: string }>
}

export interface AccountState {
  readonly state: string
  readonly credentialRequired: boolean
  readonly label?: string
}

export const record = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}

export const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

/// MSP command ids: UUIDv7 (RFC 9562), which the host requires on every
/// mutating command. The 48-bit millisecond clock leads, then random bits.
export const commandId = (now: number = Date.now(), random: Buffer = randomBytes(16)): string => {
  const bytes = Buffer.from(random)
  bytes.writeUIntBE(now, 0, 6)
  bytes[6] = (bytes[6]! & 0x0f) | 0x70
  bytes[8] = (bytes[8]! & 0x3f) | 0x80
  const hex = bytes.toString("hex")
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/// Compares dotted release numbers ("1.4.7" against "1.4.0"); a build
/// suffix ("1.4.7-R6101.1") is ignored.
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
