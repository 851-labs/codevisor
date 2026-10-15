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

export interface SharedTokenBundle {
  readonly authMethod?: "apiKey"
  readonly harnessId: SharedOAuthHarness
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
  SHARED_OAUTH_HARNESSES.some((harnessId) => harnessId === value.harnessId) &&
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

export class SharedCredentialError extends Error {
  constructor(readonly reason: "offline" | "reauthenticate" | "revoked" | "busy") {
    super(
      reason === "offline"
        ? "Account sync is unavailable. Try again when connected."
        : reason === "busy"
          ? "Account is reconnecting. Try again."
          : reason === "revoked"
            ? "This account has been signed out."
            : "Sign in again to reconnect this account on your machines."
    )
  }
}
