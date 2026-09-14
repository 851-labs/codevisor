import { APIError, createAuthEndpoint, getSessionFromCtx } from "better-auth/api"
import { setSessionCookie } from "better-auth/cookies"
import { handleOAuthUserInfo } from "better-auth/oauth2"
import { z } from "zod"
import { appleUserInfo, exchangeNativeAppleCode, hasAppleAuth } from "./apple-auth.js"
import type { CloudEnv } from "./env.js"

const challengeSchema = z.object({
  nonce: z.string(),
  userId: z.string().optional(),
  sessionId: z.string().optional()
})

export const nativeAppleAuth = (env: CloudEnv) => ({
  id: "codevisor-native-apple",
  endpoints: {
    startNativeApple: createAuthEndpoint(
      "/apple/native/start",
      {
        method: "POST",
        body: z.object({ link: z.boolean().default(false) })
      },
      async (c) => {
        if (!hasAppleAuth(env) || !env.APPLE_NATIVE_CLIENT_ID) {
          throw new APIError("NOT_FOUND", {
            message: "Native Apple sign-in is not configured on this server."
          })
        }
        const session = c.body.link ? await getSessionFromCtx(c) : null
        if (c.body.link && !session) throw new APIError("UNAUTHORIZED")
        const id = crypto.randomUUID()
        const nonce = crypto.randomUUID() + crypto.randomUUID()
        await c.context.internalAdapter.createVerificationValue({
          identifier: `native-apple:${id}`,
          value: JSON.stringify({
            nonce,
            userId: session?.user.id,
            sessionId: session?.session.id
          }),
          expiresAt: new Date(Date.now() + 10 * 60_000)
        })
        return c.json({ id, nonce })
      }
    ),
    completeNativeApple: createAuthEndpoint(
      "/apple/native/complete",
      {
        method: "POST",
        body: z.object({
          challengeId: z.string().uuid(),
          authorizationCode: z.string().min(1).max(4096),
          firstName: z.string().max(200).optional(),
          lastName: z.string().max(200).optional()
        })
      },
      async (c) => {
        if (!hasAppleAuth(env) || !env.APPLE_NATIVE_CLIENT_ID) throw new APIError("NOT_FOUND")
        // Atomic consumption prevents concurrent completion and token replay.
        const stored = await c.context.internalAdapter.consumeVerificationValue(
          `native-apple:${c.body.challengeId}`
        )
        if (!stored)
          throw new APIError("UNAUTHORIZED", {
            message: "This sign-in request expired. Please try again."
          })
        const challenge = challengeSchema.parse(JSON.parse(stored.value))
        const session = challenge.userId ? await getSessionFromCtx(c) : null
        if (
          challenge.userId &&
          (session?.user.id !== challenge.userId || session?.session.id !== challenge.sessionId)
        ) {
          throw new APIError("UNAUTHORIZED", {
            message: "Your account changed. Please try connecting again."
          })
        }
        const verified = await exchangeNativeAppleCode(
          env,
          c.body.authorizationCode,
          challenge.nonce
        ).catch(() => {
          throw new APIError("UNAUTHORIZED", {
            message: "Apple could not verify this sign-in. Please try again."
          })
        })
        const info = await appleUserInfo(env, verified.payload, c.body)
        if (!info)
          throw new APIError("UNAUTHORIZED", { message: "Apple did not provide an account email." })
        const account = {
          providerId: "apple",
          accountId: info.user.id,
          idToken: verified.tokens.id_token!,
          accessToken: verified.tokens.access_token,
          refreshToken: verified.tokens.refresh_token!
        }
        if (session) {
          const existing = await c.context.internalAdapter.findAccountByProviderId(
            account.accountId,
            "apple"
          )
          if (existing && existing.userId !== session.user.id) {
            throw new APIError("CONFLICT", {
              message: "This Apple account is already connected to another Codevisor account."
            })
          }
          if (existing) await c.context.internalAdapter.updateAccount(existing.id, account)
          else
            await c.context.internalAdapter.createAccount({ ...account, userId: session.user.id })
          await setSessionCookie(c, session)
          return c.json({ token: session.session.token })
        }
        const result = await handleOAuthUserInfo(c, { userInfo: info.user, account })
        if (result.error || !result.data) {
          throw new APIError("UNAUTHORIZED", {
            message: "Sign in with your existing method, then connect Apple in Account settings."
          })
        }
        await setSessionCookie(c, result.data)
        return c.json({ token: result.data.session.token })
      }
    )
  }
})
