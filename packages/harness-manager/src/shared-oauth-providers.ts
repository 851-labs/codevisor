import { createHash } from "node:crypto"
import { readFile, realpath } from "node:fs/promises"
import { join, resolve } from "node:path"

import { antigravityAuthPath, parseAntigravityAuth } from "./antigravity-credentials.js"
import { claudeKeychainService } from "./claude-profile-login.js"
import type { HarnessAuthExec } from "./harness-auth-types.js"
import { errnoCode, recordOrEmpty } from "./json-values.js"
import { museAuthPath, parseMuseAuth } from "./muse-credentials.js"
import {
  OAuthRefreshRejected,
  SharedCredentialError,
  type SharedOAuthHarness,
  type SharedTokenBundle
} from "./shared-credential-types.js"
import { refreshProviderOAuth } from "./shared-provider-oauth.js"

const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined
const claims = (token: string): Record<string, unknown> => {
  try {
    return recordOrEmpty(
      JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"))
    )
  } catch {
    return {}
  }
}
const refreshRejection = async (response: Response): Promise<OAuthRefreshRejected> => {
  const body = recordOrEmpty(await response.json().catch(() => undefined))
  return new OAuthRefreshRejected(response.status, string(body.error))
}
const jsonFile = async (path: string): Promise<Record<string, unknown> | undefined> => {
  try {
    return recordOrEmpty(JSON.parse(await readFile(path, "utf8")))
  } catch (cause) {
    if (errnoCode(cause) === "ENOENT") return undefined
    throw new Error("Saved sign-in could not be read", { cause })
  }
}

export const sharedOAuthIdentity = (
  bundle: Pick<SharedTokenBundle, "harnessId" | "subject" | "organizationId">
): string =>
  `shared-${createHash("sha256")
    .update(JSON.stringify([bundle.harnessId, bundle.subject, bundle.organizationId ?? ""]))
    .digest("hex")
    .slice(0, 32)}`

export const sharedApiKey = (harnessId: SharedOAuthHarness, key: string): SharedTokenBundle => ({
  harnessId,
  authMethod: "apiKey",
  subject: `key:${createHash("sha256").update(key).digest("hex")}`,
  accessToken: key,
  expiresAt: Number.MAX_SAFE_INTEGER,
  ownership: "managed"
})

export const parseCodexOAuth = (
  document: unknown,
  ownership: SharedTokenBundle["ownership"]
): SharedTokenBundle | undefined => {
  const tokens = recordOrEmpty(recordOrEmpty(document).tokens)
  const accessToken = string(tokens.access_token)
  if (!accessToken) {
    const key = string(recordOrEmpty(document).OPENAI_API_KEY)
    return key ? sharedApiKey("codex", key) : undefined
  }
  const access = claims(accessToken)
  const idToken = string(tokens.id_token)
  const identity = idToken ? claims(idToken) : access
  const auth = recordOrEmpty(
    identity["https://api.openai.com/auth"] ?? access["https://api.openai.com/auth"]
  )
  const subject = string(auth.chatgpt_user_id) ?? string(identity.sub)
  const organizationId = string(tokens.account_id) ?? string(auth.chatgpt_account_id)
  if (!subject || !organizationId || typeof access.exp !== "number") return undefined
  const email = string(identity.email)
  const planType = string(auth.chatgpt_plan_type)
  const refreshToken = ownership === "managed" ? string(tokens.refresh_token) : undefined
  return {
    harnessId: "codex",
    subject,
    organizationId,
    accessToken,
    expiresAt: access.exp * 1000,
    ownership,
    ...(email ? { email } : {}),
    ...(planType ? { planType } : {}),
    ...(idToken ? { idToken } : {}),
    ...(refreshToken ? { refreshToken } : {})
  }
}

export const parseClaudeOAuth = (
  document: unknown,
  settings: unknown,
  ownership: SharedTokenBundle["ownership"]
): SharedTokenBundle | undefined => {
  const token = recordOrEmpty(recordOrEmpty(document).claudeAiOauth)
  const identity = recordOrEmpty(recordOrEmpty(settings).oauthAccount)
  const accessToken = string(token.accessToken)
  const subject = string(identity.accountUuid)
  const organizationId = string(identity.organizationUuid)
  if (!accessToken || !subject || typeof token.expiresAt !== "number") return undefined
  const email = string(identity.emailAddress)
  const refreshToken = ownership === "managed" ? string(token.refreshToken) : undefined
  const scopes = Array.isArray(token.scopes)
    ? token.scopes.filter((scope): scope is string => typeof scope === "string")
    : undefined
  return {
    harnessId: "claude-code",
    subject,
    accessToken,
    expiresAt: token.expiresAt,
    ownership,
    ...(organizationId ? { organizationId } : {}),
    ...(email ? { email } : {}),
    ...(refreshToken ? { refreshToken } : {}),
    ...(scopes ? { scopes } : {})
  }
}

export const readNativeOAuth = async (options: {
  readonly harnessId: SharedOAuthHarness
  readonly directory: string
  readonly isDefault: boolean
  readonly ownership: SharedTokenBundle["ownership"]
  readonly env: NodeJS.ProcessEnv
  readonly exec: HarnessAuthExec
  readonly platform?: string
}): Promise<SharedTokenBundle | undefined> => {
  const { harnessId, directory, ownership } = options
  if (harnessId === "muse-code") {
    if (options.isDefault && options.env.META_API_KEY)
      return sharedApiKey(harnessId, options.env.META_API_KEY)
    const document = await jsonFile(museAuthPath(directory))
    return document === undefined ? undefined : parseMuseAuth(document, ownership)
  }
  if (harnessId === "antigravity") {
    if (options.isDefault) return undefined
    const document = await jsonFile(antigravityAuthPath(directory))
    return document === undefined ? undefined : parseAntigravityAuth(document, ownership)
  }
  const key = harnessId === "codex" ? options.env.OPENAI_API_KEY : options.env.ANTHROPIC_API_KEY
  if (options.isDefault && key) return sharedApiKey(harnessId, key)
  let document = await jsonFile(
    join(directory, harnessId === "codex" ? "auth.json" : ".credentials.json")
  )
  if ((options.platform ?? process.platform) === "darwin") {
    const canonical = await realpath(directory).catch(() => resolve(directory))
    const service =
      harnessId === "codex"
        ? "Codex Auth"
        : claudeKeychainService(directory, options.isDefault && !options.env.CLAUDE_CONFIG_DIR)
    const account =
      harnessId === "codex"
        ? `cli|${createHash("sha256").update(canonical).digest("hex").slice(0, 16)}`
        : options.env.USER
    try {
      const stored = await options.exec(
        "/usr/bin/security",
        ["find-generic-password", "-s", service, ...(account ? ["-a", account] : []), "-w"],
        { timeout: 5_000, maxBuffer: 100_000 }
      )
      document = recordOrEmpty(JSON.parse(stored.stdout))
    } catch {}
  }
  if (document === undefined) return undefined
  if (harnessId === "codex") return parseCodexOAuth(document, ownership)
  const settings =
    (await jsonFile(join(directory, ".claude.json"))) ??
    (options.isDefault && options.env.HOME
      ? await jsonFile(join(options.env.HOME, ".claude.json"))
      : undefined)
  return parseClaudeOAuth(document, settings, ownership)
}

export const refreshSharedOAuth = async (
  bundle: SharedTokenBundle,
  request: typeof fetch = fetch,
  now = Date.now()
): Promise<SharedTokenBundle> => {
  if (bundle.ownership !== "managed" || !bundle.refreshToken)
    throw new SharedCredentialError("reauthenticate")
  if (["pi", "opencode", "grok-build"].includes(bundle.harnessId))
    return refreshProviderOAuth(bundle, request, now)
  const codex = bundle.harnessId === "codex"
  const response = await request(
    codex ? "https://auth.openai.com/oauth/token" : "https://platform.claude.com/v1/oauth/token",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(codex ? {} : { "anthropic-beta": "oauth-2025-04-20" })
      },
      body: JSON.stringify({
        grant_type: "refresh_token",
        refresh_token: bundle.refreshToken,
        client_id: codex ? "app_EMoamEEZ73f0CkXaXp7hrann" : "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      }),
      redirect: "error",
      signal: AbortSignal.timeout(15_000)
    }
  )
  if (!response.ok) throw await refreshRejection(response)
  const value = recordOrEmpty(await response.json())
  const accessToken = string(value.access_token)
  const refreshToken = string(value.refresh_token) ?? bundle.refreshToken
  if (!accessToken) throw new SharedCredentialError("reauthenticate")
  if (codex) {
    const updated = parseCodexOAuth(
      {
        tokens: {
          access_token: accessToken,
          refresh_token: refreshToken,
          id_token: value.id_token ?? bundle.idToken,
          account_id: bundle.organizationId
        }
      },
      "managed"
    )
    if (updated === undefined) throw new SharedCredentialError("reauthenticate")
    return updated
  }
  if (
    typeof value.expires_in !== "number" ||
    !Number.isFinite(value.expires_in) ||
    value.expires_in <= 0
  )
    throw new SharedCredentialError("reauthenticate")
  return { ...bundle, accessToken, refreshToken, expiresAt: now + value.expires_in * 1000 }
}
