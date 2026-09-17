import { createHash } from "node:crypto"

import type { OAuthCredential, Provider } from "@earendil-works/pi-ai"
import { builtinProviders } from "@earendil-works/pi-ai/providers/all"

import { SharedCredentialError, type SharedTokenBundle } from "./shared-credential-types.js"

export type ProviderOAuthHarness = "pi" | "opencode" | "grok-build"
export const MANAGED_REFRESH_PREFIX = "codevisor:"

const object = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined
const claims = (token: string): Record<string, unknown> => {
  try {
    return object(JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString()))
  } catch {
    return {}
  }
}

// Only integrations whose refresh contract has been inspected are enrolled.
// An unknown OpenCode plugin must keep ownership of its own credentials.
export const providerOAuthSupported = (
  harness: ProviderOAuthHarness,
  providerId: string,
  providers: ReadonlyArray<Provider> = builtinProviders()
): boolean =>
  harness === "pi"
    ? providers.some((provider) => provider.id === providerId && provider.auth.oauth !== undefined)
    : harness === "grok-build"
      ? providerId === "xai"
      : ["openai", "xai", "github-copilot", "github-copilot-enterprise"].includes(providerId)

export const providerTokenEndpoint = (providerId: string): string | undefined =>
  providerId === "openai"
    ? "https://auth.openai.com/oauth/token"
    : providerId === "xai"
      ? "https://auth.x.ai/oauth2/token"
      : undefined

export const parseProviderOAuth = (
  harnessId: ProviderOAuthHarness,
  providerId: string,
  value: unknown,
  ownership: SharedTokenBundle["ownership"],
  providers?: ReadonlyArray<Provider>
): SharedTokenBundle | undefined => {
  if (!providerOAuthSupported(harnessId, providerId, providers)) return undefined
  const credential = object(value)
  const grok = harnessId === "grok-build"
  if (grok && credential.auth_mode === "api_key") {
    const key = string(credential.key)
    if (!key) return undefined
    return {
      harnessId,
      providerId,
      authMethod: "apiKey",
      ownership: "managed",
      subject: `key:${createHash("sha256").update(key).digest("hex")}`,
      accessToken: key,
      expiresAt: Number.MAX_SAFE_INTEGER
    }
  }
  if (grok ? credential.auth_mode !== "oidc" : credential.type !== "oauth") return undefined
  if (
    grok &&
    (credential.oidc_issuer !== "https://auth.x.ai" ||
      credential.oidc_client_id !== "b1a00492-073a-47ea-816f-4c329264a828")
  )
    return undefined
  const refresh = string(grok ? credential.refresh_token : credential.refresh)
  const durable = harnessId === "opencode" && providerId.startsWith("github-copilot")
  const accessToken = durable ? refresh : string(grok ? credential.key : credential.access)
  if (!accessToken || !refresh || refresh.startsWith(MANAGED_REFRESH_PREFIX)) return undefined
  const expiresAt = durable
    ? Number.MAX_SAFE_INTEGER
    : grok
      ? Date.parse(String(credential.expires_at))
      : credential.expires
  if (typeof expiresAt !== "number" || !Number.isFinite(expiresAt)) return undefined
  const accessIdentity = claims(accessToken)
  const identity = grok
    ? { ...claims(string(credential.id_token) ?? ""), ...accessIdentity }
    : accessIdentity
  const auth = object(identity["https://api.openai.com/auth"])
  const subject =
    string(auth.chatgpt_user_id) ??
    string(identity.sub) ??
    string(credential.user_id) ??
    `grant:${createHash("sha256").update(refresh).digest("hex")}`
  const organizationId =
    (grok ? (string(identity.principal_id) ?? string(identity.principalId)) : undefined) ??
    string(credential.accountId) ??
    string(auth.chatgpt_account_id) ??
    string(credential.organization_id)
  const email = string(credential.email) ?? string(identity.email)
  // Keep only access-side metadata in external mirrors. The refresh token is
  // retained only for a grant created in an isolated Codevisor login flow.
  const { refresh: _refresh, refresh_token: _grokRefresh, ...metadata } = credential
  return {
    harnessId,
    providerId,
    subject,
    accessToken,
    expiresAt,
    ownership: durable ? "managed" : ownership,
    ...(ownership === "managed" && !durable ? { refreshToken: refresh } : {}),
    ...(organizationId ? { organizationId } : {}),
    ...(email ? { email } : {}),
    credential: metadata
  }
}

export const providerCredential = (
  bundle: SharedTokenBundle,
  refresh: string
): OAuthCredential => ({
  ...bundle.credential,
  type: "oauth",
  access: bundle.accessToken,
  refresh:
    bundle.harnessId === "opencode" && bundle.providerId?.startsWith("github-copilot")
      ? bundle.accessToken
      : refresh,
  expires: bundle.expiresAt
})

export const refreshProviderOAuth = async (
  bundle: SharedTokenBundle,
  request: typeof fetch = fetch,
  now = Date.now(),
  providers: ReadonlyArray<Provider> = builtinProviders()
): Promise<SharedTokenBundle> => {
  if (!bundle.refreshToken || !bundle.providerId || bundle.ownership !== "managed")
    throw new SharedCredentialError("reauthenticate")
  if (bundle.harnessId === "pi") {
    const oauth = providers.find((provider) => provider.id === bundle.providerId)?.auth.oauth
    if (!oauth) throw new SharedCredentialError("reauthenticate")
    const credential = await oauth.refresh(
      providerCredential(bundle, bundle.refreshToken),
      AbortSignal.timeout(15_000)
    )
    if (!credential.access || !credential.refresh || !Number.isFinite(credential.expires))
      throw new SharedCredentialError("reauthenticate")
    return {
      ...bundle,
      accessToken: credential.access,
      refreshToken: credential.refresh,
      expiresAt: credential.expires,
      credential
    }
  }
  const endpoint = providerTokenEndpoint(bundle.providerId)
  if (!endpoint) throw new SharedCredentialError("reauthenticate")
  const response = await request(endpoint, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: bundle.refreshToken,
      client_id:
        bundle.providerId === "openai"
          ? "app_EMoamEEZ73f0CkXaXp7hrann"
          : "b1a00492-073a-47ea-816f-4c329264a828"
    }).toString()
  })
  if (!response.ok) throw new SharedCredentialError("reauthenticate")
  const value = object(await response.json())
  const accessToken = string(value.access_token)
  const expiresIn = value.expires_in
  if (
    !accessToken ||
    typeof expiresIn !== "number" ||
    !Number.isFinite(expiresIn) ||
    expiresIn <= 0
  )
    throw new SharedCredentialError("reauthenticate")
  return {
    ...bundle,
    accessToken,
    refreshToken: string(value.refresh_token) ?? bundle.refreshToken,
    expiresAt: now + expiresIn * 1000,
    ...(string(value.id_token) ? { idToken: string(value.id_token)! } : {})
  }
}
