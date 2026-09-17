import { setTimeout as sleep } from "node:timers/promises"

import type { OAuthAuth } from "@earendil-works/pi-ai"

export const GROK_ISSUER = "https://auth.x.ai"
export const GROK_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
// xai-org/grok-build 72a6125: auth/config.rs and auth/device_code.rs.
const scopes =
  "openid profile email offline_access grok-cli:access api:access conversations:read conversations:write workspaces:read workspaces:write"
const string = (value: unknown): string => {
  if (typeof value !== "string" || !value.trim())
    throw new Error("Invalid Grok authorization response")
  return value
}
const positive = (value: unknown): number => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0)
    throw new Error("Invalid Grok authorization expiry")
  return value
}
const verificationURL = (value: unknown) => {
  const url = new URL(string(value))
  if (url.protocol !== "https:" || url.username || url.password)
    throw new Error("Invalid Grok sign-in URL")
  return url.href
}
export const makeGrokDeviceLogin =
  (
    request: typeof fetch = fetch,
    wait: (
      delay: number,
      value: undefined,
      options: { signal?: AbortSignal | undefined }
    ) => Promise<void> = sleep,
    now: () => number = Date.now,
    elapsed: () => number = () => performance.now()
  ): OAuthAuth["login"] =>
  async (interaction) => {
    const post = async (path: string, fields: Record<string, string>) => {
      const response = await request(`${GROK_ISSUER}/oauth2/${path}`, {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.any([
          ...(interaction.signal ? [interaction.signal] : []),
          AbortSignal.timeout(15_000)
        ]),
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "x-grok-client-surface": "ui"
        },
        body: new URLSearchParams({ client_id: GROK_CLIENT_ID, ...fields })
      })
      const body = (await response.json()) as Record<string, unknown>
      if (!body || typeof body !== "object" || Array.isArray(body))
        throw new Error("Invalid Grok authorization response")
      return { ok: response.ok, body }
    }
    const device = await post("device/code", { scope: scopes, referrer: "grok-build" })
    if (!device.ok) throw new Error("Couldn't start Grok sign-in")
    const deviceCode = string(device.body.device_code)
    const userCode = string(device.body.user_code)
    const verificationUri = verificationURL(
      device.body.verification_uri_complete ?? device.body.verification_uri
    )
    const deadline = elapsed() + positive(device.body.expires_in) * 1000
    let interval = device.body.interval === undefined ? 5000 : positive(device.body.interval) * 1000
    interaction.notify({ type: "device_code", userCode, verificationUri })
    while (elapsed() < deadline) {
      await wait(Math.min(interval, deadline - elapsed()), undefined, {
        signal: interaction.signal
      })
      if (elapsed() >= deadline) break
      const token = await post("token", {
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: deviceCode
      })
      if (token.ok)
        return {
          type: "oauth",
          access: string(token.body.access_token),
          refresh: string(token.body.refresh_token),
          expires: now() + positive(token.body.expires_in) * 1000,
          ...(typeof token.body.id_token === "string" ? { idToken: token.body.id_token } : {})
        }
      if (token.body.error === "slow_down") interval += 5000
      else if (token.body.error !== "authorization_pending")
        throw new Error("Grok sign-in was declined or expired")
    }
    throw new Error("Grok sign-in code expired")
  }

export const loginGrok: OAuthAuth["login"] = (interaction) => makeGrokDeviceLogin()(interaction)
