import type { CredentialCommand, CredentialCoordinationResult } from "@codevisor/api"

export type SharedOAuthHarness = "claude-code" | "codex" | "pi" | "opencode" | "grok-build"

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
  /// Provider-specific token fields remain inside the encrypted vault.
  readonly credential?: Readonly<Record<string, unknown>>
  /// Existing terminal logins remain owned by their CLI. We may mirror their
  /// access token, but must never introduce another independent refresher.
  readonly ownership: "managed" | "external"
}

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
