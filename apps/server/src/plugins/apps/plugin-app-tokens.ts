import { createHmac, randomBytes, timingSafeEqual } from "node:crypto"

import { Schema } from "effect"

export const APP_LAUNCH_TTL_MS = 10 * 60_000

export const APP_SESSION_TTL_MS = 12 * 60 * 60_000

export type PluginAppScope =
  | { readonly kind: "view"; readonly viewId: string }
  | { readonly kind: "pane"; readonly serverId: string; readonly paneType: string }

export interface IssuedAppToken {
  readonly token: string
  readonly expiresAt: string
}

export interface PluginAppTokens {
  readonly issue: (scope: PluginAppScope, ttlMs: number) => IssuedAppToken
  readonly verify: (token: string) => PluginAppScope | undefined
}

export const makePluginAppTokens = (
  secret: Buffer = randomBytes(32),
  now: () => number = Date.now
): PluginAppTokens => {
  const sign = (payload: string): string =>
    createHmac("sha256", secret).update(payload).digest("base64url")

  return {
    issue: (scope, ttlMs) => {
      const expiresAt = now() + ttlMs
      const payload = Buffer.from(JSON.stringify({ scope, expiresAt })).toString("base64url")
      return { token: `${payload}.${sign(payload)}`, expiresAt: new Date(expiresAt).toISOString() }
    },
    verify: (token) => {
      const [payload, signature, ...rest] = token.split(".")
      if (payload === undefined || signature === undefined || rest.length > 0) return undefined
      if (!sameSignature(signature, sign(payload))) return undefined

      const claims = decodedClaims(payload)
      if (claims === undefined || claims.expiresAt <= now()) return undefined
      return claims.scope
    }
  }
}

export const sameScope = (left: PluginAppScope, right: PluginAppScope): boolean =>
  JSON.stringify(left) === JSON.stringify(right)

const Scope = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("view"), viewId: Schema.String }),
  Schema.Struct({
    kind: Schema.Literal("pane"),
    serverId: Schema.String,
    paneType: Schema.String
  })
])

const Claims = Schema.Struct({ scope: Scope, expiresAt: Schema.Number })

const sameSignature = (actual: string, expected: string): boolean => {
  const left = Buffer.from(actual)
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}

const decodedClaims = (payload: string): typeof Claims.Type | undefined => {
  try {
    return Schema.decodeUnknownSync(Claims)(
      JSON.parse(Buffer.from(payload, "base64url").toString("utf8"))
    )
  } catch {
    return undefined
  }
}
