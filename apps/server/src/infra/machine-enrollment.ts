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

export const DEFAULT_INSTALL_URL = "https://www.codevisor.dev/install.sh"

const SSH_TIMEOUT_MS = 10 * 60 * 1000
const APPEAR_TIMEOUT_MS = 60 * 1000
const APPEAR_POLL_MS = 1000
const OUTPUT_TAIL_LINES = 30
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
  readonly remove: (machine: string) => Promise<ReadonlyArray<MachineSummary>>
}

export const shellQuote = (value: string): string => `'${value.replaceAll("'", `'\\''`)}'`

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
      child.on("error", (error) => {
        if (error.name === "AbortError") resolve({ exitCode: null, output })
        else reject(new HttpFailure(501, `Couldn't run ssh on this machine: ${error.message}`))
      })
      child.on("close", (exitCode) => resolve({ exitCode, output }))
      /* v8 ignore next */
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

const validateEnrollmentRequest = (
  request: AddMachineRequest,
  destination: string
): string | undefined => {
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
  return name
}

const installFailureReason = (run: SshRun): string => {
  if (run.exitCode === null) return "timed out or was cancelled"
  if (run.exitCode === 255)
    return "could not connect over SSH (check the destination, your SSH key, and the host's firewall)"
  return `failed (exit ${run.exitCode})`
}

const successfulInstallOutput = (run: SshRun, destination: string, inviteCode: string): string => {
  const output = tail(run.output, inviteCode)
  if (run.exitCode !== 0) {
    const why = installFailureReason(run)
    throw new HttpFailure(502, `Setting up ${destination} ${why}:\n${output}`)
  }
  if (/already connected to/i.test(run.output)) {
    throw new HttpFailure(
      409,
      `${destination} is already connected to a Codevisor account. Check machines.list(), or run \`codevisor auth logout\` on it first to move it here.`
    )
  }
  return output
}

export const makeMachineEnrollment = (options: MachineEnrollmentOptions): MachineEnrollment => {
  const { cloud, link } = options
  /* v8 ignore next */
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

  const waitForJoined = async (
    before: ReadonlySet<string>,
    signal: AbortSignal | undefined
  ): Promise<CloudMachinePresence | undefined> => {
    const selfDeviceId = cloud.deviceId()
    const deadline = now() + APPEAR_TIMEOUT_MS
    let joined: CloudMachinePresence | undefined
    // oxlint-disable-next-line no-unmodified-loop-condition
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
    const name = validateEnrollmentRequest(request, destination)
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
    const output = successfulInstallOutput(run, destination, code)
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
