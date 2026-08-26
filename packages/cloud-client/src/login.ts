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

/// One machine already on the account, as the hub reports it. The login
/// flow uses this to tell a first machine (nothing to sync from) apart
/// from one joining an existing fleet.
export interface AccountMachineSummary {
  deviceId: string
  name: string
}

/// The account's registered machines, fetched with the device-flow session
/// token — available BEFORE this machine provisions itself, so callers can
/// branch on "first machine" vs "joining a fleet".
export const listAccountMachines = async (
  fetchImpl: FetchLike,
  serverUrl: string,
  sessionToken: string
): Promise<AccountMachineSummary[]> => {
  const response = await fetchImpl(`${serverUrl}/api/machines`, {
    headers: { authorization: `Bearer ${sessionToken}` }
  })
  if (!response.ok) throw new CloudApiError("machine list failed", response.status)
  const body = (await response.json()) as {
    machines?: Array<{ deviceId?: string; name?: string }>
  }
  return (body.machines ?? []).map((machine) => ({
    deviceId: machine.deviceId ?? "",
    name: machine.name ?? ""
  }))
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
      name: machineName,
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
