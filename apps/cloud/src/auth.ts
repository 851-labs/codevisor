import { apiKey } from "@better-auth/api-key"
import { drizzleAdapter } from "@better-auth/drizzle-adapter"
import { betterAuth } from "better-auth"
import { bearer, deviceAuthorization } from "better-auth/plugins"
import { oneTimeToken } from "better-auth/plugins/one-time-token"
import { drizzle } from "drizzle-orm/d1"

import { appleOptions, hasAppleAuth, revokeAppleAuthorization } from "./apple-auth.js"
import { nativeAppleAuth } from "./apple-native.js"
import * as schema from "./db/schema.js"
import { emailAuthPlugin, hasEmailAuth } from "./email-auth.js"
import { isDevAuthEnabled, type CloudEnv } from "./env.js"

export const MACHINE_CLIENT_ID = "codevisor-machine"

export const SESSION_LIFETIME_SECONDS = 60 * 60 * 24 * 365

export const createAuth = (env: CloudEnv) => {
  const database = drizzleAdapter(drizzle(env.DB, { schema }), { provider: "sqlite" })
  const devAuth = isDevAuthEnabled(env)
  const secret =
    env.BETTER_AUTH_SECRET ?? (devAuth ? "codevisor-dev-secret-not-for-production" : undefined)
  if (secret === undefined) {
    throw new Error("BETTER_AUTH_SECRET is required when DEV_AUTH is not enabled")
  }
  return betterAuth({
    baseURL: env.PUBLIC_BASE_URL,
    secret,
    database,
    socialProviders: {
      ...(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET
        ? { github: { clientId: env.GITHUB_CLIENT_ID, clientSecret: env.GITHUB_CLIENT_SECRET } }
        : {}),
      ...(hasAppleAuth(env) ? { apple: () => appleOptions(env) } : {})
    },
    trustedOrigins: ["https://appleid.apple.com"],
    account: {
      accountLinking: {
        enabled: true,
        disableImplicitLinking: true,
        allowDifferentEmails: true,
        trustedProviders: ["apple", "github"]
      }
    },
    disabledPaths: ["/unlink-account", "/sign-in/email-otp"],
    user: {
      deleteUser: {
        enabled: true,
        beforeDelete: async (user) => {
          await revokeAppleAuthorization(env, user.id)
          await env.DB.batch([
            env.DB.prepare(deleteUserSql.apiKeys).bind(user.id),
            env.DB.prepare(deleteUserSql.deviceCodes).bind(user.id),
            env.DB.prepare(deleteUserSql.verifications).bind(user.id)
          ])
          await env.USER_HUB.get(env.USER_HUB.idFromName(user.id)).deleteAccount()
        },
        afterDelete: async (user) => {
          await env.DB.prepare(deleteUserSql.apiKeys).bind(user.id).run()
        }
      }
    },
    emailAndPassword: {
      enabled: hasEmailAuth(env) || devAuth,
      requireEmailVerification: hasEmailAuth(env),
      revokeSessionsOnPasswordReset: true
    },
    emailVerification: {
      sendOnSignUp: true,
      sendOnSignIn: false,
      autoSignInAfterVerification: true
    },
    session: { expiresIn: SESSION_LIFETIME_SECONDS, updateAge: 60 * 60 * 24 },
    rateLimit: { enabled: !devAuth, storage: "database" },
    advanced: { ipAddress: { ipAddressHeaders: ["cf-connecting-ip"] } },
    plugins: [
      ...(hasEmailAuth(env) ? [emailAuthPlugin(env)] : []),
      nativeAppleAuth(env),
      bearer(),
      oneTimeToken(),
      deviceAuthorization({
        verificationUri: "/device",
        validateClient: (clientId: string) => clientId === MACHINE_CLIENT_ID,
        interval: devAuth ? "0s" : "5s"
      }),
      apiKey({ enableMetadata: true, rateLimit: { enabled: false } })
    ]
  })
}

const deleteUserSql = {
  apiKeys: "DELETE FROM apikey WHERE reference_id = ?",
  deviceCodes: "DELETE FROM device_code WHERE user_id = ?",
  verifications:
    "DELETE FROM verification WHERE value IN (SELECT token FROM session WHERE user_id = ?)"
}
