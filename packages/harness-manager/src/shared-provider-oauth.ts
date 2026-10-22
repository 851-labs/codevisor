import { createHash } from "node:crypto"

import type { OAuthCredential, Provider } from "@earendil-works/pi-ai"
import { builtinProviders } from "@earendil-works/pi-ai/providers/all"

import { recordOrEmpty } from "./json-values.js"
import { SharedCredentialError, type SharedTokenBundle } from "./shared-credential-types.js"

export type ProviderOAuthHarness = "pi" | "opencode" | "grok-build"
export const MANAGED_REFRESH_PREFIX = "codevisor:"

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined
const claims = (token: string): Record<string, unknown> => {
  try {
    return recordOrEmpty(JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString()))
  } catch {
    return {}
  }
}

export const providerOAuthSupported = (
  harness: ProviderOAuthHarness,
  providerId: string,
  providers: ReadonlyArray<Provider> = builtinProviders()
): boolean => {
  if (harness === "pi")
    return providers.some(
      (provider) => provider.id === providerId && provider.auth.oauth !== undefined
    )
  if (harness === "grok-build") return providerId === "xai"
  return ["openai", "xai", "github-copilot", "github-copilot-enterprise"].includes(providerId)
}

export const providerTokenEndpoint = (providerId: string): string | undefined => {
  if (providerId === "openai") return "https://auth.openai.com/oauth/token"
  if (providerId === "xai") return "https://auth.x.ai/oauth2/token"
  return undefined
}

const credentialExpiry = (durable: boolean, grok: boolean, credential: Record<string, unknown>) => {
  if (durable) return Number.MAX_SAFE_INTEGER
  if (grok) return Date.parse(String(credential.expires_at))
  return credential.expires
}

export const parseProviderOAuth = (
  harnessId: ProviderOAuthHarness,
  providerId: string,
  value: unknown,
  ownership: SharedTokenBundle["ownership"],
  providers?: ReadonlyArray<Provider>
): SharedTokenBundle | undefined => {
  if (!providerOAuthSupported(harnessId, providerId, providers)) return undefined
  const credential = recordOrEmpty(value)
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
  const expiresAt = credentialExpiry(durable, grok, credential)
  if (typeof expiresAt !== "number" || !Number.isFinite(expiresAt)) return undefined
  const accessIdentity = claims(accessToken)
  const identity = grok
    ? { ...claims(string(credential.id_token) ?? ""), ...accessIdentity }
    : accessIdentity
  const auth = recordOrEmpty(identity["https://api.openai.com/auth"])
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
  const value = recordOrEmpty(await response.json())
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
