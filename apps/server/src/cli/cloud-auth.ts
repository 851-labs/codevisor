import {
  CloudApiError,
  discoverInstance,
  pollDeviceToken,
  provisionMachine,
  requestDeviceCode,
  type FetchLike,
  type MachineCredentials
} from "@codevisor/cloud-client"
import type { CliDeps } from "./support.js"

/// `codevisor auth …` — connect this machine to a Codevisor Cloud account via
/// the RFC 8628 device flow, so it appears in the user's apps automatically.
/// Pure logic against CliDeps (+ an injectable fetch); wiring lives in cli.ts.

export const DEFAULT_CLOUD_URL = "https://cloud.codevisor.dev"

export const cloudCredentialsPath = (deps: CliDeps): string => `${deps.dataDir}/cloud.json`

export const readCloudCredentials = (deps: CliDeps): MachineCredentials | undefined => {
  const raw = deps.readTextFile(cloudCredentialsPath(deps))
  if (raw === undefined) return undefined
  try {
    const parsed = JSON.parse(raw) as Partial<MachineCredentials>
    if (
      typeof parsed.serverUrl === "string" &&
      typeof parsed.deviceId === "string" &&
      typeof parsed.publicKey === "string" &&
      typeof parsed.secretKey === "string" &&
      typeof parsed.apiKey === "string"
    ) {
      return parsed as MachineCredentials
    }
    return undefined
  } catch {
    return undefined
  }
}

export interface CloudAuthOptions {
  /// Base URL of the cloud instance (self-hosted or dev); defaults to the
  /// hosted instance, overridable via CODEVISOR_CLOUD_URL.
  readonly server?: string
  readonly fetchImpl?: FetchLike
  readonly machineName?: string
}

const resolveServer = (deps: CliDeps, options: CloudAuthOptions): string =>
  (options.server ?? deps.env.CODEVISOR_CLOUD_URL ?? DEFAULT_CLOUD_URL).replace(/\/+$/, "")

const resolveFetch = (options: CloudAuthOptions): FetchLike =>
  options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))

export const authLoginCommand = async (
  deps: CliDeps,
  options: CloudAuthOptions = {}
): Promise<number> => {
  const existing = readCloudCredentials(deps)
  if (existing !== undefined) {
    deps.log(`This machine is already connected to ${existing.serverUrl}.`)
    deps.log("Run `codevisor auth logout` first to connect it to a different account.")
    return 0
  }
  const serverUrl = resolveServer(deps, options)
  const fetchImpl = resolveFetch(options)
  try {
    const instance = await discoverInstance(fetchImpl, serverUrl)
    deps.log(`Connecting this machine to ${instance.instance} (${serverUrl})`)
    const grant = await requestDeviceCode(fetchImpl, serverUrl)
    deps.log("")
    deps.log("To approve, visit:")
    deps.log(`  ${grant.verificationUriComplete ?? `${serverUrl}${grant.verificationUri}`}`)
    deps.log(`and confirm the code:  ${grant.userCode}`)
    deps.log("")
    deps.log("Waiting for approval…")
    let intervalSeconds = grant.interval
    const deadline = grant.expiresIn * 1000
    let waited = 0
    for (;;) {
      if (waited > deadline) {
        deps.error("The code expired before it was approved. Run `codevisor auth login` again.")
        return 1
      }
      await deps.sleep(intervalSeconds * 1000)
      waited += intervalSeconds * 1000
      const poll = await pollDeviceToken(fetchImpl, serverUrl, grant.deviceCode)
      if (poll.status === "pending") continue
      if (poll.status === "slow-down") {
        intervalSeconds += 5
        continue
      }
      if (poll.status === "denied") {
        deps.error("The request was denied.")
        return 1
      }
      if (poll.status === "expired") {
        deps.error("The code expired before it was approved. Run `codevisor auth login` again.")
        return 1
      }
      const machineName = options.machineName ?? deps.env.HOSTNAME ?? "machine"
      const credentials = await provisionMachine(
        fetchImpl,
        serverUrl,
        poll.sessionToken,
        machineName
      )
      deps.writeTextFile(cloudCredentialsPath(deps), JSON.stringify(credentials, null, 2))
      deps.log("")
      deps.log(`✓ Connected as ${machineName}.`)
      deps.log("It will appear in your Codevisor apps once the server (re)starts.")
      return 0
    }
  } catch (error) {
    const detail =
      error instanceof CloudApiError
        ? `${error.message} (status ${error.status})`
        : error instanceof Error
          ? error.message
          : String(error)
    deps.error(`Cloud login failed: ${detail}`)
    return 1
  }
}

export const authStatusCommand = async (
  deps: CliDeps,
  options: CloudAuthOptions = {}
): Promise<number> => {
  const credentials = readCloudCredentials(deps)
  if (credentials === undefined) {
    deps.log("This machine is not connected to a Codevisor Cloud account.")
    deps.log("Run `codevisor auth login` to connect it.")
    return 0
  }
  deps.log(`Connected to ${credentials.serverUrl}`)
  deps.log(`  device id: ${credentials.deviceId}`)
  try {
    const instance = await discoverInstance(resolveFetch(options), credentials.serverUrl)
    deps.log(`  instance:  ${instance.instance} (v${instance.version})`)
  } catch {
    deps.log("  instance:  unreachable right now")
  }
  return 0
}

export const authLogoutCommand = async (deps: CliDeps): Promise<number> => {
  const credentials = readCloudCredentials(deps)
  if (credentials === undefined) {
    deps.log("This machine is not connected to a Codevisor Cloud account.")
    return 0
  }
  deps.removeFile(cloudCredentialsPath(deps))
  deps.log(`Disconnected this machine from ${credentials.serverUrl}.`)
  deps.log(
    "To revoke its credential too, remove the machine from your machine list in the Codevisor app."
  )
  return 0
}
