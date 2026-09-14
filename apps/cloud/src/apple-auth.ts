import type { AppleOptions } from "better-auth/social-providers"
import {
  createRemoteJWKSet,
  decodeJwt,
  importPKCS8,
  jwtVerify,
  SignJWT,
  type JWTPayload
} from "jose"
import type { CloudEnv } from "./env.js"

const issuer = "https://appleid.apple.com"
const appleKeys = createRemoteJWKSet(new URL(`${issuer}/auth/keys`))

export const hasAppleAuth = (env: CloudEnv): boolean =>
  Boolean(env.APPLE_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY)

/// Sign short-lived client assertions on demand. A deployed Worker never
/// depends on an expiring six-month secret copied from a developer's laptop.
export const appleClientSecret = async (
  env: CloudEnv,
  clientId = env.APPLE_CLIENT_ID!
): Promise<string> => {
  if (!hasAppleAuth(env)) throw new Error("Sign in with Apple is not configured")
  const key = await importPKCS8(env.APPLE_PRIVATE_KEY!, "ES256")
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID! })
    .setIssuer(env.APPLE_TEAM_ID!)
    .setSubject(clientId)
    .setAudience(issuer)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key)
}

export const appleOptions = async (env: CloudEnv): Promise<AppleOptions> => ({
  // The Services ID is grouped with the native iOS App ID in Apple Developer.
  // Both resolve by Apple subject; email (including relay email) is not identity.
  clientId: env.APPLE_CLIENT_ID!,
  clientSecret: await appleClientSecret(env),
  disableIdTokenSignIn: true,
  getUserInfo: async (tokens) => {
    if (!tokens.idToken) return null
    const verified = await jwtVerify(tokens.idToken, appleKeys, {
      issuer,
      audience: env.APPLE_CLIENT_ID!,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "iat", "exp"],
      maxTokenAge: "10m"
    }).catch(() => null)
    if (!verified) return null
    const { payload } = verified
    if (typeof payload.sub !== "string" || !payload.sub) return null
    return appleUserInfo(
      env,
      payload,
      (tokens as typeof tokens & { user?: { name?: { firstName?: unknown; lastName?: unknown } } })
        .user?.name
    )
  }
})

export const appleUserInfo = async (
  env: CloudEnv,
  payload: JWTPayload,
  suppliedName?: { firstName?: unknown; lastName?: unknown }
) => {
  if (typeof payload.sub !== "string" || !payload.sub) return null
  // Resolve omitted profile fields by verified subject, never by email.
  const existing = await env.DB.prepare(
    `SELECT u.email, u.name, u.email_verified FROM account a
       JOIN user u ON u.id = a.user_id WHERE a.provider_id = 'apple' AND a.account_id = ?`
  )
    .bind(payload.sub)
    .first<{ email: string; name: string; email_verified: number }>()
  const email = typeof payload.email === "string" ? payload.email : existing?.email
  if (!email) return null
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

/// Native authorization codes are single-use and exchanged for this exact App ID.
/// The nonce ties Apple's response to a challenge issued by this Cloud instance.
export const exchangeNativeAppleCode = async (env: CloudEnv, code: string, nonce: string) => {
  const clientId = env.APPLE_NATIVE_CLIENT_ID!
  const response = await fetch(`${issuer}/auth/token`, {
    method: "POST",
    signal: AbortSignal.timeout(10_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: await appleClientSecret(env, clientId),
      grant_type: "authorization_code",
      code
    })
  })
  if (!response.ok) throw new Error("Apple could not verify this sign-in. Please try again.")
  const tokens = (await response.json()) as {
    id_token?: string
    access_token?: string
    refresh_token?: string
  }
  if (!tokens.id_token || !tokens.refresh_token)
    throw new Error("Apple did not complete sign-in. Please try again.")
  const { payload } = await jwtVerify(tokens.id_token, appleKeys, {
    issuer,
    audience: clientId,
    algorithms: ["RS256"],
    requiredClaims: ["sub", "iat", "exp", "nonce"],
    maxTokenAge: "10m"
  })
  if (payload.nonce !== nonce)
    throw new Error("This Apple sign-in request has expired. Please try again.")
  return { tokens, payload }
}

/// Run before deleting account records: keep the refresh token available if
/// Apple is temporarily unavailable so the user can retry the whole operation.
export const revokeAppleAuthorization = async (env: CloudEnv, userId: string): Promise<void> => {
  const { results } = await env.DB.prepare(
    "SELECT refresh_token, access_token, id_token FROM account WHERE user_id = ? AND provider_id = 'apple'"
  )
    .bind(userId)
    .all<{ refresh_token: string | null; access_token: string | null; id_token: string | null }>()
  for (const account of results) {
    const token = account.refresh_token ?? account.access_token
    if (!token) throw new Error("Sign in with Apple again before deleting your account")
    // Stored ID tokens were verified before saving. Their audience identifies
    // whether Apple issued this refresh token to the Services ID or native App ID.
    const clientId = account.id_token ? decodeJwt(account.id_token).aud : env.APPLE_CLIENT_ID
    if (
      typeof clientId !== "string" ||
      ![env.APPLE_CLIENT_ID, env.APPLE_NATIVE_CLIENT_ID].includes(clientId)
    ) {
      throw new Error("Sign in with Apple again before deleting your account")
    }
    const response = await fetch(`${issuer}/auth/revoke`, {
      method: "POST",
      signal: AbortSignal.timeout(10_000),
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: await appleClientSecret(env, clientId),
        token,
        token_type_hint: account.refresh_token ? "refresh_token" : "access_token"
      })
    })
    if (!response.ok) throw new Error("Apple authorization could not be revoked. Please try again.")
    await response.body?.cancel()
  }
}
