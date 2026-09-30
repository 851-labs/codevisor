import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

export const MACHINE_CLIENT_ID = "codevisor-machine"

export class CloudApiError extends Error {
  constructor(
    message: string,
    readonly status: number
  ) {
    super(message)
    this.name = "CloudApiError"
  }
}

const postJson = async (
  fetchImpl: FetchLike,
  url: string,
  body: unknown,
  headers: Record<string, string> = {}
): Promise<Response> =>
  fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body)
  })

export interface DeviceCodeGrant {
  deviceCode: string
  userCode: string
  verificationUri: string
  verificationUriComplete?: string
  /// Seconds between token polls.
  interval: number
  /// Seconds until the codes expire.
  expiresIn: number
}

/// Start the RFC 8628 device flow: returns the code the user must approve at
/// `<serverUrl>/device`.
export const requestDeviceCode = async (
  fetchImpl: FetchLike,
  serverUrl: string
): Promise<DeviceCodeGrant> => {
  const response = await postJson(fetchImpl, `${serverUrl}/api/auth/device/code`, {
    client_id: MACHINE_CLIENT_ID
  })
  if (!response.ok) throw new CloudApiError("device code request failed", response.status)
  const body = (await response.json()) as {
    device_code: string
    user_code: string
    verification_uri: string
    verification_uri_complete?: string
    interval?: number
    expires_in?: number
  }
  return {
    deviceCode: body.device_code,
    userCode: body.user_code,
    verificationUri: body.verification_uri,
    ...(body.verification_uri_complete !== undefined
      ? { verificationUriComplete: body.verification_uri_complete }
      : {}),
    interval: body.interval ?? 5,
    expiresIn: body.expires_in ?? 1800
  }
}

export type DevicePollResult =
  | { status: "granted"; sessionToken: string }
  | { status: "pending" }
  | { status: "slow-down" }
  | { status: "denied" }
  | { status: "expired" }

/// One token poll. Callers loop on pending/slow-down at the grant's interval.
export const pollDeviceToken = async (
  fetchImpl: FetchLike,
  serverUrl: string,
  deviceCode: string
): Promise<DevicePollResult> => {
  const response = await postJson(fetchImpl, `${serverUrl}/api/auth/device/token`, {
    grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    device_code: deviceCode,
    client_id: MACHINE_CLIENT_ID
  })
  if (response.ok) {
    const body = (await response.json()) as { access_token: string }
    return { status: "granted", sessionToken: body.access_token }
  }
  const body = (await response.json().catch(() => ({}))) as { error?: string }
  switch (body.error) {
    case "authorization_pending":
      return { status: "pending" }
    case "slow_down":
      return { status: "slow-down" }
    case "access_denied":
      return { status: "denied" }
    case "expired_token":
      return { status: "expired" }
    default:
      throw new CloudApiError(body.error ?? "device token poll failed", response.status)
  }
}

/// A machine's stored cloud identity: everything needed to reconnect to the
/// hub across restarts. `secretKey` never leaves the machine.
export interface MachineCredentials {
  serverUrl: string
  deviceId: string
  publicKey: string
  secretKey: string
  apiKey: string
}

/// Exchange a (possibly short-lived) session token for the machine's durable
/// identity: fresh device keypair + long-lived api key carrying the device
/// metadata the relay needs.
export const provisionMachine = async (
  fetchImpl: FetchLike,
  serverUrl: string,
  sessionToken: string,
  machineName: string
): Promise<MachineCredentials> => {
  const deviceId = crypto.randomUUID()
  const keys = generateDeviceKeyPair()
  const response = await postJson(
    fetchImpl,
    `${serverUrl}/api/auth/api-key/create`,
    {
      // Credential labels have a 32-character limit. The relay advertises
      // the full display name independently, including long hostnames.
      name: machineName.slice(0, 32),
      metadata: { deviceId, publicKey: keys.publicKey }
    },
    { authorization: `Bearer ${sessionToken}` }
  )
  if (!response.ok) throw new CloudApiError("machine credential creation failed", response.status)
  const body = (await response.json()) as { key: string }
  return {
    serverUrl,
    deviceId,
    publicKey: keys.publicKey,
    secretKey: keys.secretKey,
    apiKey: body.key
  }
}

/// Removes this machine from its account (`codevisor auth logout`): the
/// cloud revokes the machine's api key and drops it from every app's machine
/// list. Authenticated by the machine's own api key. Throws CloudApiError on
/// a refusal — 401 means the key is no longer valid (the machine was already
/// removed, or the account is gone).
export const removeMachineFromAccount = async (
  fetchImpl: FetchLike,
  credentials: Pick<MachineCredentials, "serverUrl" | "apiKey">,
  signal?: AbortSignal
): Promise<void> => {
  const response = await fetchImpl(`${credentials.serverUrl}/api/machine/self`, {
    method: "DELETE",
    headers: { "x-api-key": credentials.apiKey },
    ...(signal === undefined ? {} : { signal })
  })
  if (!response.ok) throw new CloudApiError("machine removal failed", response.status)
}

export interface CloudInstanceInfo {
  service: string
  instance: string
  version: string
  protocols: number[]
  authProviders: string[]
}

/// Validate a server URL before trusting it (settings UI, `--server` flag).
export const discoverInstance = async (
  fetchImpl: FetchLike,
  serverUrl: string
): Promise<CloudInstanceInfo> => {
  const response = await fetchImpl(`${serverUrl}/.well-known/codevisor`)
  if (!response.ok) throw new CloudApiError("instance discovery failed", response.status)
  const body = (await response.json()) as CloudInstanceInfo
  if (body.service !== "codevisor-cloud") {
    throw new CloudApiError("not a codevisor cloud instance", 200)
  }
  return body
}

// -- Machine invites -----------------------------------------------------------

/// Prefix of a machine invite code. The code carries the cloud's URL so the
/// new machine joins the same instance (hosted, self-hosted, or dev) as the
/// machine that minted it: `cvi1.<base64url(serverUrl)>.<secret>`.
const INVITE_PREFIX = "cvi1"

const toBase64Url = (text: string): string =>
  btoa(String.fromCharCode(...new TextEncoder().encode(text)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "")

const fromBase64Url = (value: string): string => {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4))
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)))
}

export interface MachineInvite {
  /// Pass to `codevisor auth login --invite` on the new machine. Secret:
  /// anyone holding it can add one machine to the account until it expires.
  readonly code: string
  readonly expiresAt: string
}

export const encodeMachineInviteCode = (serverUrl: string, token: string): string =>
  `${INVITE_PREFIX}.${toBase64Url(serverUrl.replace(/\/+$/, ""))}.${token}`

/// The cloud URL and secret inside an invite code; undefined when malformed.
export const decodeMachineInviteCode = (
  code: string
): { readonly serverUrl: string; readonly token: string } | undefined => {
  const [prefix, server, token, ...rest] = code.trim().split(".")
  if (prefix !== INVITE_PREFIX || server === undefined || token === undefined || rest.length > 0) {
    return undefined
  }
  if (!/^[A-Za-z0-9_-]{20,200}$/.test(token)) return undefined
  try {
    const serverUrl = fromBase64Url(server)
    const parsed = new URL(serverUrl)
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return undefined
    return { serverUrl, token }
  } catch {
    return undefined
  }
}

/// Mint a one-time invite as this machine (authenticated by its api key).
export const createMachineInvite = async (
  fetchImpl: FetchLike,
  credentials: Pick<MachineCredentials, "serverUrl" | "apiKey">
): Promise<MachineInvite> => {
  const serverUrl = credentials.serverUrl.replace(/\/+$/, "")
  const response = await fetchImpl(`${serverUrl}/api/machine/invites`, {
    method: "POST",
    headers: { "x-api-key": credentials.apiKey }
  })
  const body = (await response.json().catch(() => ({}))) as {
    token?: string
    expiresAt?: string
    error?: string
  }
  if (!response.ok || body.token === undefined || body.expiresAt === undefined) {
    throw new CloudApiError(body.error ?? "machine invite failed", response.status)
  }
  return {
    code: encodeMachineInviteCode(serverUrl, body.token),
    expiresAt: body.expiresAt
  }
}

/// Redeem an invite code for this machine's durable identity: a fresh device
/// keypair (the secret key never leaves this machine) and its own api key.
export const redeemMachineInvite = async (
  fetchImpl: FetchLike,
  code: string,
  machineName: string
): Promise<MachineCredentials> => {
  const invite = decodeMachineInviteCode(code)
  if (invite === undefined) throw new CloudApiError("not a Codevisor machine invite code", 400)
  const deviceId = crypto.randomUUID()
  const keys = generateDeviceKeyPair()
  const response = await postJson(fetchImpl, `${invite.serverUrl}/api/machine/invites/redeem`, {
    token: invite.token,
    name: machineName,
    deviceId,
    publicKey: keys.publicKey
  })
  const body = (await response.json().catch(() => ({}))) as { key?: string; error?: string }
  if (!response.ok || body.key === undefined) {
    throw new CloudApiError(body.error ?? "machine invite redemption failed", response.status)
  }
  return {
    serverUrl: invite.serverUrl,
    deviceId,
    publicKey: keys.publicKey,
    secretKey: keys.secretKey,
    apiKey: body.key
  }
}

/// Removes another machine from this machine's account. 404 when the account
/// has no such machine.
export const removeMachinePeer = async (
  fetchImpl: FetchLike,
  credentials: Pick<MachineCredentials, "serverUrl" | "apiKey">,
  deviceId: string
): Promise<void> => {
  const response = await fetchImpl(
    `${credentials.serverUrl}/api/machine/peers/${encodeURIComponent(deviceId)}`,
    { method: "DELETE", headers: { "x-api-key": credentials.apiKey } }
  )
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string }
    throw new CloudApiError(body.error ?? "machine removal failed", response.status)
  }
}
