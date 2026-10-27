import type { CredentialCommand, CredentialCoordinationResult } from "@codevisor/api"

import { isRecord } from "./json-values.js"

const SHARED_OAUTH_HARNESSES = [
  "codex",
  "claude-code",
  "pi",
  "opencode",
  "grok-build",
  "muse-code",
  "antigravity"
] as const

export type SharedOAuthHarness = (typeof SHARED_OAUTH_HARNESSES)[number]
export type SharedCredentialKind = SharedOAuthHarness | "mcp" | "plugin"

export interface SharedTokenBundle {
  readonly authMethod?: "apiKey"
  readonly harnessId: SharedCredentialKind
  readonly subject: string
  readonly organizationId?: string
  readonly email?: string
  readonly accessToken: string
  readonly refreshToken?: string
  readonly idToken?: string
  readonly expiresAt: number
  readonly planType?: string
  readonly scopes?: ReadonlyArray<string>
  readonly providerId?: string
  readonly credential?: Readonly<Record<string, unknown>>
  readonly ownership: "managed" | "external"
}

const isOptionalString = (value: unknown): boolean =>
  value === undefined || typeof value === "string"

export const isSharedTokenBundle = (value: unknown): value is SharedTokenBundle =>
  isRecord(value) &&
  (value.harnessId === "mcp" ||
    value.harnessId === "plugin" ||
    SHARED_OAUTH_HARNESSES.some((harnessId) => harnessId === value.harnessId)) &&
  typeof value.subject === "string" &&
  typeof value.accessToken === "string" &&
  Number.isFinite(value.expiresAt) &&
  (value.ownership === "managed" || value.ownership === "external") &&
  (value.authMethod === undefined || value.authMethod === "apiKey") &&
  [
    value.organizationId,
    value.email,
    value.refreshToken,
    value.idToken,
    value.planType,
    value.providerId
  ].every(isOptionalString) &&
  (value.scopes === undefined ||
    (Array.isArray(value.scopes) && value.scopes.every((scope) => typeof scope === "string"))) &&
  (value.credential === undefined || isRecord(value.credential))

export interface SharedCredentialReference {
  readonly id: string
  readonly key: string
}

export type CredentialCoordinator = (
  id: string,
  command: CredentialCommand
) => Promise<CredentialCoordinationResult>

type SharedCredentialFailure = "offline" | "reauthenticate" | "revoked" | "busy"

const sharedCredentialMessage = (reason: SharedCredentialFailure): string => {
  if (reason === "offline") return "Account sync is unavailable. Try again when connected."
  if (reason === "busy") return "Account is reconnecting. Try again."
  if (reason === "revoked") return "This account has been signed out."
  return "Sign in again to reconnect this account on your machines."
}

export class SharedCredentialError extends Error {
  constructor(readonly reason: SharedCredentialFailure) {
    super(sharedCredentialMessage(reason))
  }
}

export class OAuthRefreshUnavailable extends SharedCredentialError {
  constructor(readonly detail: string) {
    super("offline")
  }
}

export class OAuthRefreshRejected extends SharedCredentialError {
  constructor(
    readonly status: number,
    readonly code: string | undefined
  ) {
    super("reauthenticate")
  }
}
