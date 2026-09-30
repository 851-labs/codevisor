import {
  CloudApiError,
  decodeMachineInviteCode,
  discoverInstance,
  pollDeviceToken,
  requestDeviceCode,
  type DeviceCodeGrant,
  type FetchLike
} from "@codevisor/cloud-client"

import {
  cloudUrl,
  ensureCloudServer,
  readCloudRegistration,
  waitForCloudConnection
} from "./cloud-control.js"
import { renderQr } from "./qr.js"
import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"

/// `codevisor auth …` — connect this machine to a Codevisor Cloud account via
/// the RFC 8628 device flow, so it appears in the user's apps automatically
/// and joins the account's config sync.
/// Pure logic against CliDeps (+ an injectable fetch); wiring lives in cli.ts.

const DEFAULT_CLOUD_URL = "https://cloud.codevisor.dev"

export interface CloudAuthOptions extends CommandOptions {
  /// Base URL of the cloud instance (self-hosted or dev); defaults to the
  /// hosted instance, overridable via CODEVISOR_CLOUD_URL.
  readonly server?: string
  readonly fetchImpl?: FetchLike
  readonly machineName?: string
  /// A one-time invite from another machine on the account
  /// (`codevisor machines invite`): joins without a person approving.
  readonly inviteCode?: string
}

/// The absolute approval URL with the code filled in, so opening it (or
/// scanning it with the Codevisor app) skips typing the code.
const approvalUrl = (grant: DeviceCodeGrant, serverUrl: string): string => {
  const url = new URL(grant.verificationUriComplete ?? grant.verificationUri, `${serverUrl}/`)
  if (!url.searchParams.has("user_code")) url.searchParams.set("user_code", grant.userCode)
  return url.toString()
}

const resolveServer = (deps: CliDeps, options: CloudAuthOptions): string =>
  (options.server ?? deps.env.CODEVISOR_CLOUD_URL ?? DEFAULT_CLOUD_URL).replace(/\/+$/, "")

const resolveFetch = (options: CloudAuthOptions): FetchLike =>
  options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))

/// Hands the invite to the running server, which redeems it for this
/// machine's own credential and connects; succeeds once the relay is up.
const joinWithInvite = async (
  deps: CliDeps,
  port: number,
  inviteCode: string,
  machineName: string | undefined
): Promise<number> => {
  const invite = decodeMachineInviteCode(inviteCode)
  if (invite === undefined) {
    deps.error("That isn't a Codevisor machine invite. Create one with: codevisor machines invite")
    return 1
  }
  deps.log(`Joining the account on ${invite.serverUrl} with a machine invite…`)
  const response = await deps.fetchJson(`${cloudUrl(port)}/connect`, {
    method: "POST",
    timeoutMs: 30_000,
    body: {
      inviteCode,
      managedBy: "external",
      ...(machineName === undefined ? {} : { machineName })
    }
  })
  const body = response?.body as { deviceId?: string; error?: string } | undefined
  if (response?.status !== 200 || typeof body?.deviceId !== "string") {
    deps.error(`Couldn't join with the invite: ${body?.error ?? "the server did not answer"}`)
    deps.error("Invites work once and expire after 10 minutes; create a new one and retry.")
    return 1
  }
  await waitForCloudConnection(deps, port, body.deviceId)
  deps.log(`✓ Connected${machineName === undefined ? "" : ` as ${machineName}`}.`)
  deps.log("This machine is online in your Codevisor apps.")
  return 0
}

export const authLoginCommand = async (
  deps: CliDeps,
  options: CloudAuthOptions = {}
): Promise<number> => {
  const serverUrl = resolveServer(deps, options)
  const fetchImpl = resolveFetch(options)
  try {
    const port = await resolvePort(deps, options.port)
    const existing = await ensureCloudServer(deps, port)
    if (existing.deviceId !== undefined) {
      await waitForCloudConnection(deps, port, existing.deviceId)
      deps.log(`This machine is already connected to ${existing.serverUrl ?? "Codevisor Cloud"}.`)
      deps.log("Run `codevisor auth logout` first to connect it to a different account.")
      return 0
    }
    if (options.inviteCode !== undefined) {
      return await joinWithInvite(deps, port, options.inviteCode, options.machineName)
    }
    const instance = await discoverInstance(fetchImpl, serverUrl)
    deps.log(`Logging this machine in to ${instance.instance} (${serverUrl})`)
    const grant = await requestDeviceCode(fetchImpl, serverUrl)
    const approval = approvalUrl(grant, serverUrl)
    // The link comes last: in a short terminal it stays on screen, and the
    // QR code is a scroll up.
    deps.log("")
    deps.log("Scan to log in with the Codevisor app on your phone:")
    deps.log("")
    for (const line of renderQr(approval)) deps.log(`  ${line}`)
    deps.log("")
    deps.log("Or log in from a browser:")
    deps.log(`  ${approval}`)
    deps.log(`  Code: ${grant.userCode}`)
    deps.log("")
    deps.log("Waiting for you to log in…")
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
      const response = await deps.fetchJson(`${cloudUrl(port)}/connect`, {
        method: "POST",
        timeoutMs: 30_000,
        body: { serverUrl, sessionToken: poll.sessionToken, machineName, managedBy: "external" }
      })
      const body = response?.body as { deviceId?: string; error?: string } | undefined
      if (response?.status !== 200 || typeof body?.deviceId !== "string") {
        throw new Error(body?.error ?? "The server could not save the Cloud registration")
      }
      await waitForCloudConnection(deps, port, body.deviceId)
      deps.log("")
      deps.log(`✓ Connected as ${machineName}.`)
      deps.log("This machine is online in your Codevisor apps.")
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
  try {
    const port = await resolvePort(deps, options.port)
    const registration = await readCloudRegistration(deps, port)
    if (registration === undefined) {
      deps.error(`Codevisor server is not running on port ${port}; start it with: codevisor start`)
      return 1
    }
    if (registration.deviceId === undefined) {
      deps.log("This machine is not connected to a Codevisor Cloud account.")
      deps.log("Run `codevisor auth login` to connect it.")
      return 0
    }
    const state = registration.state ?? "unknown"
    deps.log(
      `${state === "connected" ? "Connected to" : "Registered with"} ${registration.serverUrl ?? "Codevisor Cloud"}`
    )
    deps.log(`  device id: ${registration.deviceId}`)
    deps.log(`  relay:     ${state}`)
    return state === "connected" ? 0 : 1
  } catch (error) {
    deps.error(`Cloud status failed: ${String(error)}`)
    return 1
  }
}

export const authLogoutCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  try {
    const port = await resolvePort(deps, options.port)
    const registration = await ensureCloudServer(deps, port)
    if (registration.deviceId === undefined) {
      deps.log("This machine is not connected to a Codevisor Cloud account.")
      return 0
    }
    const response = await deps.fetchJson(`${cloudUrl(port)}/disconnect`, {
      method: "POST",
      // The server waits a bounded time for the cloud before disconnecting.
      timeoutMs: 30_000
    })
    if (response?.status !== 200)
      throw new Error("The server could not remove the Cloud registration")
    const cloud = registration.serverUrl ?? "Codevisor Cloud"
    const body = response.body as { readonly removedFromAccount?: unknown } | undefined
    if (body?.removedFromAccount === true) {
      deps.log(`Disconnected this machine from ${cloud} and removed it from your account.`)
      return 0
    }
    deps.log(`Disconnected this machine from ${cloud}.`)
    deps.error("Warning: this machine could not be removed from your account.")
    deps.error("Remove it from the machine list in the Codevisor app.")
    return 0
  } catch (error) {
    deps.error(`Cloud logout failed: ${String(error)}`)
    return 1
  }
}
