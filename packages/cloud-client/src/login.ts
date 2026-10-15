import { isRecord } from "@codevisor/api"
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

const readJson = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json()
  return isRecord(body) ? body : {}
}

const readErrorJson = (response: Response): Promise<Record<string, unknown>> =>
  readJson(response).catch(() => ({}))

const optionalString = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

const optionalNumber = (value: unknown): number | undefined =>
  typeof value === "number" ? value : undefined

const requiredString = (value: unknown, response: Response, message: string): string => {
  if (typeof value !== "string") throw new CloudApiError(message, response.status)
  return value
}

export interface DeviceCodeGrant {
  deviceCode: string
  userCode: string
  verificationUri: string
  verificationUriComplete?: string
  interval: number
  expiresIn: number
}

export const requestDeviceCode = async (
  fetchImpl: FetchLike,
  serverUrl: string
): Promise<DeviceCodeGrant> => {
  const response = await postJson(fetchImpl, `${serverUrl}/api/auth/device/code`, {
    client_id: MACHINE_CLIENT_ID
  })
  if (!response.ok) throw new CloudApiError("device code request failed", response.status)
  const body = await readJson(response)
  const malformed = "malformed device code response"
  const verificationUriComplete = optionalString(body.verification_uri_complete)
  return {
    deviceCode: requiredString(body.device_code, response, malformed),
    userCode: requiredString(body.user_code, response, malformed),
    verificationUri: requiredString(body.verification_uri, response, malformed),
    ...(verificationUriComplete !== undefined ? { verificationUriComplete } : {}),
    interval: optionalNumber(body.interval) ?? 5,
    expiresIn: optionalNumber(body.expires_in) ?? 1800
  }
}

export type DevicePollResult =
  | { status: "granted"; sessionToken: string }
  | { status: "pending" }
  | { status: "slow-down" }
  | { status: "denied" }
  | { status: "expired" }

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
    const body = await readJson(response)
    return {
      status: "granted",
      sessionToken: requiredString(body.access_token, response, "malformed device token response")
    }
  }
  const error = optionalString((await readErrorJson(response)).error)
  switch (error) {
    case "authorization_pending":
      return { status: "pending" }
    case "slow_down":
      return { status: "slow-down" }
    case "access_denied":
      return { status: "denied" }
    case "expired_token":
      return { status: "expired" }
    default:
      throw new CloudApiError(error ?? "device token poll failed", response.status)
  }
}

export interface MachineCredentials {
  serverUrl: string
  deviceId: string
  publicKey: string
  secretKey: string
  apiKey: string
}

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
      name: machineName.slice(0, 32),
      metadata: { deviceId, publicKey: keys.publicKey }
    },
    { authorization: `Bearer ${sessionToken}` }
  )
  if (!response.ok) throw new CloudApiError("machine credential creation failed", response.status)
  const body = await readJson(response)
  return {
    serverUrl,
    deviceId,
    publicKey: keys.publicKey,
    secretKey: keys.secretKey,
    apiKey: requiredString(body.key, response, "malformed machine credential response")
  }
}

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

const isArrayOf = (value: unknown, type: "string" | "number"): boolean =>
  Array.isArray(value) && value.every((entry) => typeof entry === type)

const isCloudInstanceInfo = (value: unknown): value is CloudInstanceInfo =>
  isRecord(value) &&
  value.service === "codevisor-cloud" &&
  typeof value.instance === "string" &&
  typeof value.version === "string" &&
  isArrayOf(value.protocols, "number") &&
  isArrayOf(value.authProviders, "string")

export const discoverInstance = async (
  fetchImpl: FetchLike,
  serverUrl: string
): Promise<CloudInstanceInfo> => {
  const response = await fetchImpl(`${serverUrl}/.well-known/codevisor`)
  if (!response.ok) throw new CloudApiError("instance discovery failed", response.status)
  const body: unknown = await response.json()
  if (!isCloudInstanceInfo(body)) {
    throw new CloudApiError("not a codevisor cloud instance", 200)
  }
  return body
}

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
  readonly code: string
  readonly expiresAt: string
}

export const encodeMachineInviteCode = (serverUrl: string, token: string): string =>
  `${INVITE_PREFIX}.${toBase64Url(serverUrl.replace(/\/+$/, ""))}.${token}`

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

export const createMachineInvite = async (
  fetchImpl: FetchLike,
  credentials: Pick<MachineCredentials, "serverUrl" | "apiKey">
): Promise<MachineInvite> => {
  const serverUrl = credentials.serverUrl.replace(/\/+$/, "")
  const response = await fetchImpl(`${serverUrl}/api/machine/invites`, {
    method: "POST",
    headers: { "x-api-key": credentials.apiKey }
  })
  const body = await readErrorJson(response)
  const token = optionalString(body.token)
  const expiresAt = optionalString(body.expiresAt)
  if (!response.ok || token === undefined || expiresAt === undefined) {
    throw new CloudApiError(optionalString(body.error) ?? "machine invite failed", response.status)
  }
  return {
    code: encodeMachineInviteCode(serverUrl, token),
    expiresAt
  }
}

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
  const body = await readErrorJson(response)
  const apiKey = optionalString(body.key)
  if (!response.ok || apiKey === undefined) {
    throw new CloudApiError(
      optionalString(body.error) ?? "machine invite redemption failed",
      response.status
    )
  }
  return {
    serverUrl: invite.serverUrl,
    deviceId,
    publicKey: keys.publicKey,
    secretKey: keys.secretKey,
    apiKey
  }
}

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
    const error = optionalString((await readErrorJson(response)).error)
    throw new CloudApiError(error ?? "machine removal failed", response.status)
  }
}
