import {
  type AddedDesktop,
  AddMachineResponse,
  MachineInviteResponse,
  MachinesResponse,
  type MachineSummary
} from "@codevisor/api"
import { Schema } from "effect"

import { resolvePort, routeFailure, type CliDeps, type CommandOptions } from "./support.js"

const machinesUrl = (port: number, path = ""): string =>
  `http://127.0.0.1:${port}/v1/machines${path}`

const machinePresence = (machine: MachineSummary): string => {
  if (machine.isCurrent) return "(this machine)"
  if (machine.online) return "online"
  return "offline"
}

const describeMachine = (machine: MachineSummary): string =>
  [
    machine.name,
    machinePresence(machine),
    ...(machine.os === undefined ? [] : [machine.os]),
    ...(machine.addedBy === undefined ? [] : [`added by ${machine.addedBy}`]),
    machine.id
  ].join("  ")

export const machinesListCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(machinesUrl(port))
  if (response?.status !== 200) {
    deps.error(`Couldn't list machines: ${routeFailure(response, port)}`)
    return 1
  }
  for (const machine of Schema.decodeUnknownSync(MachinesResponse)(response.body).machines) {
    deps.log(describeMachine(machine))
  }
  return 0
}

export const machinesInviteCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(machinesUrl(port, "/invite"), {
    method: "POST",
    timeoutMs: 30_000
  })
  if (response?.status !== 201) {
    deps.error(`Couldn't create an invite: ${routeFailure(response, port)}`)
    return 1
  }
  const invite = Schema.decodeUnknownSync(MachineInviteResponse)(response.body)
  deps.log(invite.code)
  deps.error(`One-time invite, valid until ${invite.expiresAt}. On the new machine run:`)
  deps.error("  codevisor auth login --invite <code>   (or pass - and pipe the code on stdin)")
  return 0
}

export interface MachinesAddOptions extends CommandOptions {
  readonly ssh: string
  readonly name?: string
  readonly sshPort?: number
  readonly desktop?: boolean
}

const addTimeoutMs = 11 * 60 * 1000
const desktopSetupExtraMs = 17 * 60 * 1000

export const machinesAddCommand = async (
  deps: CliDeps,
  options: MachinesAddOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const withDesktop = options.desktop === true
  deps.log(
    withDesktop
      ? `Installing Codevisor on ${options.ssh} with a desktop and adding it to your account…`
      : `Installing Codevisor on ${options.ssh} and adding it to your account…`
  )
  const response = await deps.fetchJson(machinesUrl(port, "/add"), {
    method: "POST",
    timeoutMs: addTimeoutMs + (withDesktop ? desktopSetupExtraMs : 0),
    body: {
      ssh: options.ssh,
      ...(options.name === undefined ? {} : { name: options.name }),
      ...(options.sshPort === undefined ? {} : { sshPort: options.sshPort }),
      ...(withDesktop ? { desktop: true } : {})
    }
  })
  if (response?.status !== 201) {
    deps.error(`Couldn't add ${options.ssh}: ${routeFailure(response, port)}`)
    return 1
  }
  const { machine, desktop } = Schema.decodeUnknownSync(AddMachineResponse)(response.body)
  deps.log(`✓ ${machine.name} is on your account (${machine.online ? "online" : "offline"}).`)
  if (withDesktop) deps.log(desktopLine(desktop))
  return 0
}

const desktopLine = (desktop: AddedDesktop | undefined): string => {
  if (desktop === "ready") return "  Its desktop is running. Open it from the machine in Codevisor."

  return "  Its desktop wasn't set up. The Desktop card on the machine in Codevisor says why and offers to try again."
}

export const machinesRemoveCommand = async (
  deps: CliDeps,
  options: CommandOptions & { readonly machine: string }
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(
    machinesUrl(port, `/${encodeURIComponent(options.machine)}`),
    { method: "DELETE", timeoutMs: 30_000 }
  )
  if (response?.status !== 200) {
    deps.error(`Couldn't remove ${options.machine}: ${routeFailure(response, port)}`)
    return 1
  }
  deps.log(`✓ Removed ${options.machine} from your account.`)
  return 0
}
