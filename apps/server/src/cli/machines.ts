import {
  AddMachineResponse,
  MachineInviteResponse,
  MachinesResponse,
  type MachineSummary
} from "@codevisor/api"
import { Schema } from "effect"

import { field } from "../unknown-values.js"
import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"

const machinesUrl = (port: number, path = ""): string =>
  `http://127.0.0.1:${port}/v1/machines${path}`

const failure = (
  response: { readonly status: number; readonly body: unknown } | undefined,
  port: number
): string => {
  if (response === undefined) {
    return `Codevisor server is not running on port ${port}; start it with: codevisor start`
  }
  const error = field(response.body, "error")
  return typeof error === "string" ? error : `the server answered HTTP ${response.status}`
}

const describeMachine = (machine: MachineSummary): string =>
  [
    machine.name,
    machine.isCurrent ? "(this machine)" : machine.online ? "online" : "offline",
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
    deps.error(`Couldn't list machines: ${failure(response, port)}`)
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
    deps.error(`Couldn't create an invite: ${failure(response, port)}`)
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
}

export const machinesAddCommand = async (
  deps: CliDeps,
  options: MachinesAddOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  deps.log(`Installing Codevisor on ${options.ssh} and adding it to your account…`)
  const response = await deps.fetchJson(machinesUrl(port, "/add"), {
    method: "POST",
    timeoutMs: 11 * 60 * 1000,
    body: {
      ssh: options.ssh,
      ...(options.name === undefined ? {} : { name: options.name }),
      ...(options.sshPort === undefined ? {} : { sshPort: options.sshPort })
    }
  })
  if (response?.status !== 201) {
    deps.error(`Couldn't add ${options.ssh}: ${failure(response, port)}`)
    return 1
  }
  const { machine } = Schema.decodeUnknownSync(AddMachineResponse)(response.body)
  deps.log(`✓ ${machine.name} is on your account (${machine.online ? "online" : "offline"}).`)
  return 0
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
    deps.error(`Couldn't remove ${options.machine}: ${failure(response, port)}`)
    return 1
  }
  deps.log(`✓ Removed ${options.machine} from your account.`)
  return 0
}
