import { spawn } from "node:child_process"
import { setTimeout as delay } from "node:timers/promises"

import type {
  AddMachineRequest,
  CloudMachinePresence,
  MachineInviteResponse,
  MachineSummary
} from "@codevisor/api"
import { CloudApiError } from "@codevisor/cloud-client"

import { HttpFailure } from "../server-context.js"
import type { MachineLink } from "./machine-link.js"

/// Adding and removing machines on this machine's account, shared by the
/// CLI (`codevisor machines …`) and the agent tools (`machines.invite`,
/// `machines.add`, `machines.remove`) through the /v1/machines routes.
///
/// `add` sets a host up end to end from here: it mints a one-time invite,
/// runs the public installer on the host over SSH with the invite on the
/// script's stdin (never in argv, a file, or the caller's context), and
/// waits until the new machine is online on the account.

export const DEFAULT_INSTALL_URL = "https://www.codevisor.dev/install.sh"

/// How long a host gets to download, install, and join.
const SSH_TIMEOUT_MS = 10 * 60 * 1000
/// How long a joined machine gets to show up online in hub presence.
const APPEAR_TIMEOUT_MS = 60 * 1000
const APPEAR_POLL_MS = 1000
/// Trailing output kept for error messages.
const OUTPUT_TAIL_LINES = 30
/// Output kept while the install runs, so a chatty host can't grow memory.
const OUTPUT_BUFFER_CHARS = 128_000

export interface SshRun {
  readonly exitCode: number | null
  readonly output: string
}

export interface MachineEnrollmentCloud {
  readonly deviceId: () => string | undefined
  readonly machines: () => ReadonlyArray<CloudMachinePresence> | undefined
  readonly invite: () => Promise<{ readonly code: string; readonly expiresAt: string }>
  readonly removePeer: (deviceId: string) => Promise<void>
}

export interface MachineEnrollmentOptions {
  readonly cloud: MachineEnrollmentCloud
  readonly link: MachineLink
  readonly installUrl?: string
  /// The ssh executable (default: `ssh` on PATH).
  readonly sshCommand?: string
  readonly runSsh?: (
    args: ReadonlyArray<string>,
    stdin: string,
    signal: AbortSignal
  ) => Promise<SshRun>
  readonly sleep?: (ms: number) => Promise<void>
  readonly now?: () => number
}

export interface MachineEnrollment {
  readonly invite: () => Promise<MachineInviteResponse>
  readonly add: (request: AddMachineRequest, signal?: AbortSignal) => Promise<MachineSummary>
  /// Removes another machine by id or name; resolves to the remaining list.
  readonly remove: (machine: string) => Promise<ReadonlyArray<MachineSummary>>
}

/// POSIX single-quoting: safe for any string inside `sh`.
export const shellQuote = (value: string): string => `'${value.replaceAll("'", `'\\''`)}'`

/// The script `sh -s` runs on the host. The installer sees CODEVISOR_INVITE,
/// joins the account with it, and skips the interactive onboarding.
export const remoteInstallScript = (options: {
  readonly inviteCode: string
  readonly installUrl: string
  readonly name?: string
}): string =>
  [
    "set -eu",
    `CODEVISOR_INVITE=${shellQuote(options.inviteCode)}`,
    "CODEVISOR_NO_SETUP=1",
    "export CODEVISOR_INVITE CODEVISOR_NO_SETUP",
    ...(options.name === undefined
      ? []
      : [`CODEVISOR_MACHINE_NAME=${shellQuote(options.name)}`, "export CODEVISOR_MACHINE_NAME"]),
    `url=${shellQuote(options.installUrl)}`,
    'command -v curl >/dev/null 2>&1 || { echo "codevisor: this host needs curl" >&2; exit 1; }',
    'curl -fsSL "$url" | sh',
    ""
  ].join("\n")

/// `ssh` arguments for one non-interactive run. No `-t`: without a terminal
/// the installer never starts interactive onboarding. BatchMode fails fast
/// instead of prompting for a password; accept-new trusts a fresh host's key
/// on first contact (and still refuses a changed one).
export const sshArgs = (destination: string, port: number | undefined): string[] => [
  "-o",
  "BatchMode=yes",
  "-o",
  "ConnectTimeout=15",
  "-o",
  "StrictHostKeyChecking=accept-new",
  "-o",
  "ServerAliveInterval=15",
  ...(port === undefined ? [] : ["-p", String(port)]),
  "--",
  destination,
  "sh -s"
]

const validDestination = (value: string): boolean =>
  value.length > 0 && value.length <= 255 && !value.startsWith("-") && !/\s/.test(value)

const tail = (output: string, secret: string): string =>
  output.replaceAll(secret, "[invite]").trimEnd().split("\n").slice(-OUTPUT_TAIL_LINES).join("\n")

const spawnSsh =
  (command: string) =>
  (args: ReadonlyArray<string>, stdin: string, signal: AbortSignal): Promise<SshRun> =>
    new Promise((resolve, reject) => {
      const child = spawn(command, [...args], { stdio: ["pipe", "pipe", "pipe"], signal })
      let output = ""
      const collect = (chunk: Buffer): void => {
        output = (output + chunk.toString("utf8")).slice(-OUTPUT_BUFFER_CHARS)
      }
      child.stdout.on("data", collect)
      child.stderr.on("data", collect)
      // Cancelled or timed out: report it like an interrupted run. Anything
      // else means ssh couldn't start here at all (missing, not executable).
      child.on("error", (error) => {
        if (error.name === "AbortError") resolve({ exitCode: null, output })
        else reject(new HttpFailure(501, `Couldn't run ssh on this machine: ${error.message}`))
      })
      child.on("close", (exitCode) => resolve({ exitCode, output }))
      // ssh that fails before reading the script (unreachable host, refused
      // key) closes the pipe; the exit code above reports that. An unhandled
      // EPIPE here would exit the server instead.
      /* v8 ignore next -- the script fits in the pipe buffer, so tests' early-exiting fakes never see EPIPE. */
      child.stdin.on("error", () => undefined)
      child.stdin.end(stdin)
    })

const cloudFailure = (cause: unknown, action: string): HttpFailure => {
  if (cause instanceof HttpFailure) return cause
  if (cause instanceof CloudApiError) {
    return new HttpFailure(502, cause.message)
  }
  const message = cause instanceof Error ? cause.message : String(cause)
  return new HttpFailure(
    message.includes("not connected") ? 409 : 502,
    `${action} failed: ${message}`
  )
}

export const makeMachineEnrollment = (options: MachineEnrollmentOptions): MachineEnrollment => {
  const { cloud, link } = options
  /* v8 ignore next -- production runs the system ssh; tests point sshCommand at a fake. */
  const runSsh = options.runSsh ?? spawnSsh(options.sshCommand ?? "ssh")
  const sleep = options.sleep ?? delay
  const now = options.now ?? Date.now

  const invite = async (): Promise<MachineInviteResponse> => {
    try {
      return await cloud.invite()
    } catch (cause) {
      throw cloudFailure(cause, "Creating a machine invite")
    }
  }

  /// The machine our invite added: new since `before`, added by this machine.
  const waitForJoined = async (
    before: ReadonlySet<string>,
    signal: AbortSignal | undefined
  ): Promise<CloudMachinePresence | undefined> => {
    const selfDeviceId = cloud.deviceId()
    const deadline = now() + APPEAR_TIMEOUT_MS
    let joined: CloudMachinePresence | undefined
    while (signal?.aborted !== true) {
      joined = (cloud.machines() ?? []).find(
        (presence) => !before.has(presence.deviceId) && presence.addedBy?.deviceId === selfDeviceId
      )
      if (joined?.online === true || now() >= deadline) return joined
      await sleep(APPEAR_POLL_MS)
    }
    return joined
  }

  const summaryFor = async (presence: CloudMachinePresence): Promise<MachineSummary> => {
    const id = presence.serverId ?? `cloud:${presence.deviceId}`
    const listed = (await link.list()).find((machine) => machine.id === id)
    return (
      listed ?? {
        id,
        name: presence.name,
        ...(presence.os === undefined ? {} : { os: presence.os }),
        online: presence.online,
        lastSeen: presence.lastSeenAt,
        isCurrent: false,
        ...(presence.addedBy === undefined ? {} : { addedBy: presence.addedBy.name })
      }
    )
  }

  const add = async (request: AddMachineRequest, signal?: AbortSignal): Promise<MachineSummary> => {
    const destination = request.ssh.trim()
    if (!validDestination(destination)) {
      throw new HttpFailure(400, "ssh must be a destination like root@203.0.113.7 or a Host alias")
    }
    const name = request.name?.trim()
    if (name !== undefined && (name.length === 0 || name.length > 120)) {
      throw new HttpFailure(400, "name must contain 1 to 120 characters")
    }
    if (
      request.sshPort !== undefined &&
      (!Number.isInteger(request.sshPort) || request.sshPort < 1 || request.sshPort > 65_535)
    ) {
      throw new HttpFailure(400, "sshPort must be a port number")
    }
    const { code } = await invite()
    const before = new Set((cloud.machines() ?? []).map((presence) => presence.deviceId))
    const timeout = AbortSignal.timeout(SSH_TIMEOUT_MS)
    const run = await runSsh(
      sshArgs(destination, request.sshPort),
      remoteInstallScript({
        inviteCode: code,
        installUrl: options.installUrl ?? DEFAULT_INSTALL_URL,
        ...(name === undefined ? {} : { name })
      }),
      signal === undefined ? timeout : AbortSignal.any([signal, timeout])
    )
    const output = tail(run.output, code)
    if (run.exitCode !== 0) {
      const why =
        run.exitCode === null
          ? "timed out or was cancelled"
          : run.exitCode === 255
            ? "could not connect over SSH (check the destination, your SSH key, and the host's firewall)"
            : `failed (exit ${run.exitCode})`
      throw new HttpFailure(502, `Setting up ${destination} ${why}:\n${output}`)
    }
    if (/already connected to/i.test(run.output)) {
      throw new HttpFailure(
        409,
        `${destination} is already connected to a Codevisor account. Check machines.list(), or run \`codevisor auth logout\` on it first to move it here.`
      )
    }
    const joined = await waitForJoined(before, signal)
    if (joined === undefined) {
      throw new HttpFailure(
        504,
        `Codevisor was installed on ${destination}, but it didn't appear on the account. Its output:\n${output}`
      )
    }
    return summaryFor(joined)
  }

  const remove = async (machine: string): Promise<ReadonlyArray<MachineSummary>> => {
    const target = link.resolve(machine)
    if (target === "self") {
      throw new HttpFailure(
        400,
        "That's this machine. Run `codevisor auth logout` on it to remove it from the account."
      )
    }
    if (target === undefined) throw new HttpFailure(404, `No machine "${machine}" on this account`)
    try {
      await cloud.removePeer(target.deviceId)
    } catch (cause) {
      if (cause instanceof CloudApiError && cause.status === 404) {
        throw new HttpFailure(404, `No machine "${machine}" on this account`)
      }
      throw cloudFailure(cause, `Removing ${target.name}`)
    }
    return (await link.list()).filter((summary) => summary.id !== target.id)
  }

  return { invite, add, remove }
}
