import { APIError, createAuthMiddleware } from "better-auth/api"
import { emailOTP } from "better-auth/plugins"
import type { CloudEnv } from "./env.js"

export const hasEmailAuth = (env: CloudEnv): boolean => Boolean(env.RESEND_API_KEY)

export const emailAuthPlugin = (env: CloudEnv) => {
  let deliveryFailed = false
  const plugin = emailOTP({
    otpLength: 6,
    expiresIn: 600,
    allowedAttempts: 5,
    storeOTP: "hashed",
    disableSignUp: true,
    overrideDefaultEmailVerification: true,
    async sendVerificationOTP({ email, otp, type }) {
      if (type === "sign-in") {
        throw new APIError("BAD_REQUEST", { message: "Sign in with your password." })
      }
      try {
        await sendAuthEmail(env, email, otp, type === "forget-password")
      } catch (error) {
        deliveryFailed = true
        throw error
      }
    }
  })
  return {
    ...plugin,
    hooks: {
      before: [
        {
          matcher: (ctx: { path?: string }) => ctx.path === "/email-otp/send-verification-otp",
          handler: createAuthMiddleware(async (ctx) => {
            if (ctx.body?.type === "sign-in") {
              throw new APIError("BAD_REQUEST", { message: "Sign in with your password." })
            }
          })
        }
      ],
      after: [
        ...plugin.hooks.after,
        {
          matcher: () => deliveryFailed,
          // Better Auth catches mail callback errors. Surface a safe, retryable result to native forms.
          handler: createAuthMiddleware(async () => {
            throw new APIError("SERVICE_UNAVAILABLE", {
              code: "EMAIL_DELIVERY_FAILED",
              message: "Couldn't send your code. Please try again."
            })
          })
        }
      ]
    }
  }
}

export async function sendAuthEmail(env: CloudEnv, email: string, code: string, reset: boolean) {
  const title = reset ? "Reset your password" : "Verify your email"
  const instruction = reset
    ? "Enter this code in Codevisor to reset your password."
    : "Enter this code in Codevisor to finish creating your account."
  try {
    const response = await (env.AUTH_EMAIL_FETCH ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json"
      },
      signal: AbortSignal.timeout(10_000),
      body: JSON.stringify({
        from: env.AUTH_EMAIL_FROM ?? "Codevisor <noreply@auth.codevisor.dev>",
        to: [email],
        subject: `${title} — Codevisor`,
        text: `${title}\n\n${instruction}\n\n${code}\n\nThis code expires in 10 minutes. If you didn't request it, you can ignore this email.`,
        html: `<div style="font-family:-apple-system,BlinkMacSystemFont,Arial,sans-serif;max-width:480px;margin:40px auto;color:#171717"><p style="font-weight:600">Codevisor</p><h1 style="font-size:24px">${title}</h1><p>${instruction}</p><p style="font-size:32px;font-weight:600;letter-spacing:8px">${code}</p><p>This code expires in 10 minutes.</p><p style="color:#737373;font-size:13px">If you didn't request it, you can ignore this email.</p></div>`
      })
    })
    if (!response.ok) throw new Error("Email delivery failed")
  } catch {
    // Do not log recipient addresses, codes, credentials, or provider responses.
    throw new APIError("SERVICE_UNAVAILABLE", {
      code: "EMAIL_DELIVERY_FAILED",
      message: "Couldn't send your code. Please try again."
    })
  }
}
