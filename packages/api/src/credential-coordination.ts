import { Schema } from "effect"

/// Opaque encrypted credentials. The coordinator never receives the encryption
/// key, account email, provider tokens, or provider refresh request.
export const CredentialCommand = Schema.Union([
  Schema.Struct({ action: Schema.Literal("read") }),
  Schema.Struct({ action: Schema.Literal("seed"), sealed: Schema.String }),
  Schema.Struct({
    action: Schema.Literal("acquire"),
    generation: Schema.Number,
    operationId: Schema.String
  }),
  Schema.Struct({ action: Schema.Literal("start"), operationId: Schema.String }),
  Schema.Struct({
    action: Schema.Literal("commit"),
    operationId: Schema.String,
    sealed: Schema.String
  }),
  Schema.Struct({ action: Schema.Literal("release"), operationId: Schema.String }),
  Schema.Struct({ action: Schema.Literal("revoke") })
])
export type CredentialCommand = typeof CredentialCommand.Type

export interface CoordinatedCredential {
  readonly generation: number
  readonly sealed: string
  readonly revoked: boolean
}

export interface CredentialCoordinationResult {
  readonly status: "ready" | "acquired" | "busy" | "uncertain" | "missing" | "revoked"
  readonly credential?: CoordinatedCredential
}
