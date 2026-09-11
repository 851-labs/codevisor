import type { AppleOptions } from "better-auth/social-providers"
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "jose"
import type { CloudEnv } from "./env.js"

const issuer = "https://appleid.apple.com"
const appleKeys = createRemoteJWKSet(new URL(`${issuer}/auth/keys`))

export const hasAppleAuth = (env: CloudEnv): boolean =>
  Boolean(env.APPLE_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY)

/// Sign short-lived client assertions on demand. A deployed Worker never
/// depends on an expiring six-month secret copied from a developer's laptop.
export const appleClientSecret = async (env: CloudEnv): Promise<string> => {
  if (!hasAppleAuth(env)) throw new Error("Sign in with Apple is not configured")
  const key = await importPKCS8(env.APPLE_PRIVATE_KEY!, "ES256")
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID! })
    .setIssuer(env.APPLE_TEAM_ID!)
    .setSubject(env.APPLE_CLIENT_ID!)
    .setAudience(issuer)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key)
}

export const appleOptions = async (env: CloudEnv): Promise<AppleOptions> => ({
  // Both native apps use this same web OAuth client and therefore the same
  // provider/accountId pair. Email (including Apple's relay email) is not identity.
  clientId: env.APPLE_CLIENT_ID!,
  clientSecret: await appleClientSecret(env),
  disableIdTokenSignIn: true,
  getUserInfo: async (tokens) => {
    if (!tokens.idToken) return null
    const { payload } = await jwtVerify(tokens.idToken, appleKeys, {
      issuer,
      audience: env.APPLE_CLIENT_ID!,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "iat", "exp"],
      maxTokenAge: "10m"
    })
    if (typeof payload.sub !== "string" || !payload.sub) return null
    // Returning authorizations may omit profile fields. Resolve them only
    // through the previously verified Apple subject, never by matching email.
    const existing = await env.DB.prepare(
      `SELECT u.email, u.name, u.email_verified FROM account a
       JOIN user u ON u.id = a.user_id WHERE a.provider_id = 'apple' AND a.account_id = ?`
    )
      .bind(payload.sub)
      .first<{ email: string; name: string; email_verified: number }>()
    const email = typeof payload.email === "string" ? payload.email : existing?.email
    if (!email) return null
    const suppliedName = (
      tokens as typeof tokens & {
        user?: { name?: { firstName?: unknown; lastName?: unknown } }
      }
    ).user?.name
    const name = [suppliedName?.firstName, suppliedName?.lastName]
      .filter((part): part is string => typeof part === "string")
      .join(" ")
      .trim()
      .slice(0, 200)
    return {
      user: {
        id: payload.sub,
        email,
        emailVerified:
          payload.email === undefined
            ? existing?.email_verified === 1
            : payload.email_verified === true || payload.email_verified === "true",
        name: existing?.name || name || "Codevisor User"
      },
      data: payload
    }
  }
})

/// Run before deleting account records: keep the refresh token available if
/// Apple is temporarily unavailable so the user can retry the whole operation.
export const revokeAppleAuthorization = async (env: CloudEnv, userId: string): Promise<void> => {
  const { results } = await env.DB.prepare(
    "SELECT refresh_token, access_token FROM account WHERE user_id = ? AND provider_id = 'apple'"
  )
    .bind(userId)
    .all<{ refresh_token: string | null; access_token: string | null }>()
  for (const account of results) {
    const token = account.refresh_token ?? account.access_token
    if (!token) throw new Error("Sign in with Apple again before deleting your account")
    const response = await fetch(`${issuer}/auth/revoke`, {
      method: "POST",
      signal: AbortSignal.timeout(10_000),
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.APPLE_CLIENT_ID!,
        client_secret: await appleClientSecret(env),
        token,
        token_type_hint: account.refresh_token ? "refresh_token" : "access_token"
      })
    })
    if (!response.ok) throw new Error("Apple authorization could not be revoked. Please try again.")
    await response.body?.cancel()
  }
}
