import { apiKey } from "@better-auth/api-key"
import { drizzleAdapter } from "@better-auth/drizzle-adapter"
import { betterAuth } from "better-auth"
import { bearer, deviceAuthorization } from "better-auth/plugins"
import { oneTimeToken } from "better-auth/plugins/one-time-token"
import { drizzle } from "drizzle-orm/d1"
import * as schema from "./db/schema.js"
import { DEV_USER, isDevAuthEnabled, type CloudEnv } from "./env.js"

/// Client ids accepted by the device-authorization flow. Machines are the only
/// device-flow consumer today; apps use the browser + one-time-token handoff.
export const MACHINE_CLIENT_ID = "codevisor-machine"

/// D1 bindings only exist per-request, so auth must be built per request (and
/// per DO call) rather than at module scope.
export const createAuth = (env: CloudEnv) => {
  const database = drizzleAdapter(drizzle(env.DB, { schema }), { provider: "sqlite" })
  const devAuth = isDevAuthEnabled(env)
  const secret =
    env.BETTER_AUTH_SECRET ?? (devAuth ? "codevisor-dev-secret-not-for-production" : undefined)
  if (secret === undefined) {
    throw new Error("BETTER_AUTH_SECRET is required when DEV_AUTH is not enabled")
  }
  const github =
    env.GITHUB_CLIENT_ID !== undefined && env.GITHUB_CLIENT_SECRET !== undefined
      ? {
          socialProviders: {
            github: { clientId: env.GITHUB_CLIENT_ID, clientSecret: env.GITHUB_CLIENT_SECRET }
          }
        }
      : {}
  return betterAuth({
    baseURL: env.PUBLIC_BASE_URL,
    secret,
    database,
    ...github,
    /// Dev-only credential login (see /dev/login route); never enabled unless
    /// the instance explicitly opted in via the DEV_AUTH var.
    emailAndPassword: { enabled: devAuth },
    rateLimit: { storage: "database" },
    plugins: [
      /// Native apps hold tokens, not cookies: session token arrives in the
      /// `set-auth-token` header and is sent back as `Authorization: Bearer`.
      bearer(),
      /// Browser-OAuth → native-app handoff: the /auth/handoff page generates
      /// a single-use token the app exchanges for its session.
      oneTimeToken(),
      /// `codevisor auth login`: RFC 8628 device flow, approved on /device.
      deviceAuthorization({
        verificationUri: "/device",
        validateClient: (clientId: string) => clientId === MACHINE_CLIENT_ID,
        // Dev instances (and tests) poll immediately; real instances keep the
        // RFC-friendly 5s minimum.
        interval: devAuth ? "0s" : "5s"
      }),
      /// Long-lived per-machine credentials, listed/revoked from app settings.
      /// Metadata carries the machine's deviceId + static public key.
      apiKey({
        enableMetadata: true,
        rateLimit: {
          enabled: true,
          timeWindow: 1000 * 60 * 60 * 24,
          maxRequests: 10_000
        }
      })
    ]
  })
}

export type CloudAuth = ReturnType<typeof createAuth>

export const DEV_USER_CREDENTIALS = DEV_USER
