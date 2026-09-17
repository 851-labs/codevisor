import {
  CloudApiError,
  discoverInstance,
  pollDeviceToken,
  listAccountMachines,
  requestDeviceCode,
  type AccountMachineSummary,
  type FetchLike
} from "@codevisor/cloud-client"

import {
  cloudUrl,
  ensureCloudServer,
  readCloudRegistration,
  waitForCloudConnection
} from "./cloud-control.js"
import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"
import { applySyncParticipation } from "./sync.js"

/// `codevisor auth …` — connect this machine to a Codevisor Cloud account via
/// the RFC 8628 device flow, so it appears in the user's apps automatically.
/// Pure logic against CliDeps (+ an injectable fetch); wiring lives in cli.ts.

export const DEFAULT_CLOUD_URL = "https://cloud.codevisor.dev"

export interface CloudAuthOptions extends CommandOptions {
  /// Base URL of the cloud instance (self-hosted or dev); defaults to the
  /// hosted instance, overridable via CODEVISOR_CLOUD_URL.
  readonly server?: string
  readonly fetchImpl?: FetchLike
  readonly machineName?: string
  /// Explicit config-sync choice (--no-sync); wins over the prompt.
  readonly syncConfig?: boolean
  /// Interactive fallback: ask after a successful login. Absent (plus no
  /// explicit choice) leaves the server's default — participating — alone.
  readonly promptSyncConfig?: () => Promise<boolean>
}

/// The onboarding opt-in: after connecting to a cloud account, record
/// whether this machine joins config sync. The flag lives in the local
/// server's database, so it survives subsequent restarts.
///
/// Fleet awareness: the account's machine list (fetched during login)
/// decides whether asking even makes sense. The FIRST machine has nothing
/// to sync from, so it is never prompted — the server default
/// (participating) simply applies to whatever fleet grows from here. Only
/// a machine joining an existing fleet gets the question; when the list
/// could not be fetched, the ask is kept rather than guessed away.
const applyLoginSyncChoice = async (
  deps: CliDeps,
  options: CloudAuthOptions,
  fleet: ReadonlyArray<AccountMachineSummary> | undefined
): Promise<void> => {
  let wanted = options.syncConfig
  if (wanted === undefined) {
    if (options.promptSyncConfig === undefined) return
    if (fleet !== undefined && fleet.length === 0) {
      deps.log("This is the first machine on your account, so config sync is on by default.")
      deps.log("Machines you connect later will be asked whether to join.")
      return
    }
    if (fleet !== undefined && fleet.length > 0) {
      const names = fleet.map((machine) => machine.name).join(", ")
      const plural = fleet.length === 1 ? "machine" : "machines"
      deps.log(`This account already has ${fleet.length} ${plural}: ${names}.`)
    }
    wanted = await options.promptSyncConfig()
  }
  if (await applySyncParticipation(deps, wanted, options.port)) {
    deps.log(`Config sync is ${wanted ? "on" : "off"} for this machine.`)
    return
  }
  deps.log(`Could not apply config sync; retry with: codevisor sync ${wanted ? "on" : "off"}`)
}

const resolveServer = (deps: CliDeps, options: CloudAuthOptions): string =>
  (options.server ?? deps.env.CODEVISOR_CLOUD_URL ?? DEFAULT_CLOUD_URL).replace(/\/+$/, "")

const resolveFetch = (options: CloudAuthOptions): FetchLike =>
  options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init))

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
      // Fleet awareness for the sync ask below — fetched only when a
      // prompt could happen, so piped installs stay network-silent. An
      // unreachable list degrades to "unknown", which keeps the ask.
      const fleet =
        options.syncConfig === undefined && options.promptSyncConfig !== undefined
          ? await listAccountMachines(fetchImpl, serverUrl, poll.sessionToken).catch(
              () => undefined
            )
          : undefined
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
      await applyLoginSyncChoice(deps, { ...options, port }, fleet)
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
    const response = await deps.fetchJson(`${cloudUrl(port)}/disconnect`, { method: "POST" })
    if (response?.status !== 200)
      throw new Error("The server could not remove the Cloud registration")
    deps.log(`Disconnected this machine from ${registration.serverUrl ?? "Codevisor Cloud"}.`)
    deps.log(
      "To revoke its credential too, remove the machine from your machine list in the Codevisor app."
    )
    return 0
  } catch (error) {
    deps.error(`Cloud logout failed: ${String(error)}`)
    return 1
  }
}
