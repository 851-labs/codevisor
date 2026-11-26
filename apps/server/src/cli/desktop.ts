import { DesktopStatus } from "@codevisor/api"
import { Schema } from "effect"

import { resolvePort, routeFailure, type CliDeps, type CommandOptions } from "./support.js"

export interface DesktopCliDeps extends CliDeps {
  readonly isInteractive: boolean
  readonly confirm: (question: string) => Promise<boolean>
}

export interface DesktopCommandOptions extends CommandOptions {
  readonly yes?: boolean
}

type Commands = ReadonlyArray<ReadonlyArray<string>>

interface AdministratorStep {
  readonly what: string
  readonly path: string
  readonly commands: Commands
}

const quickMs = 30_000
const startMs = 2 * 60 * 1000
const installMs = 25 * 60 * 1000

export const desktopSetupCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const server = await desktopServer(deps, options)
  deps.log("==> Checking this machine")
  const found = await server.ask("GET", "", quickMs)
  if (found === undefined) return 1

  deps.log(`    ${found.system}, ${describeState(found)}`)
  const cleared = await replaceOldDesktop(deps, server, found, options)
  if (cleared === undefined) return 1

  const equipped = await installWhatIsMissing(deps, server, cleared)
  if (equipped === undefined) return 1

  deps.log(`==> Starting the desktop as ${equipped.account}`)
  const started = await server.ask("POST", "/start", startMs)
  if (started === undefined) return 1

  deps.log("==> The desktop is ready. Open it from this machine in Codevisor.")
  if (started.startAtBootHint !== undefined)
    deps.log(`    It starts at boot once this account lingers: ${started.startAtBootHint}`)
  return 0
}

export const desktopStatusCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const status = await (await desktopServer(deps, options)).ask("GET", "", quickMs)
  if (status === undefined) return 1

  for (const line of statusLines(status)) deps.log(line)
  return 0
}

export const desktopRemoveCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const question = "Remove the desktop? This closes everything open in it."
  if (!(await agreed(deps, options, question))) return 1

  const removed = await (await desktopServer(deps, options)).ask("DELETE", "", startMs)
  if (removed === undefined) return 1

  deps.log("The desktop is removed. Its packages stay installed.")
  return 0
}

interface DesktopServer {
  readonly ask: (
    method: string,
    path: string,
    timeoutMs: number
  ) => Promise<DesktopStatus | undefined>
}

const desktopServer = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions
): Promise<DesktopServer> => {
  const port = await resolvePort(deps, options.port)
  return {
    ask: async (method, path, timeoutMs) => {
      const response = await deps.fetchJson(`http://127.0.0.1:${port}/v1/desktop${path}`, {
        method,
        timeoutMs
      })
      if (response?.status === 200) return Schema.decodeUnknownSync(DesktopStatus)(response.body)

      deps.error(routeFailure(response, port))
      return undefined
    }
  }
}

const describeState = (status: DesktopStatus): string => {
  if (status.state === "running") return "a desktop is running"
  if (status.state === "stopped") return "a desktop is set up but not running"
  if (status.state === "outdated") return "a desktop set up for an older Codevisor"

  return "no desktop set up"
}

const statusLines = (status: DesktopStatus): ReadonlyArray<string> => [
  ...stateLines(status),
  ...(status.oldDesktop === undefined
    ? []
    : [
        `An older desktop still runs as root (${status.oldDesktop.units.join(", ") || "vncserver"}). Replace it with: codevisor desktop setup`
      ])
]

const stateLines = (status: DesktopStatus): ReadonlyArray<string> => {
  if (status.state === "none")
    return ["No desktop on this machine. Set one up with: codevisor desktop setup"]
  if (status.state === "outdated")
    return [
      "This machine's desktop was set up for an older version of Codevisor.",
      "Set it up again with: codevisor desktop setup"
    ]

  const where = status.display === undefined ? "" : ` on display :${status.display}`
  const head =
    status.state === "running"
      ? `The desktop is running as ${status.account}${where}.`
      : `The desktop is set up as ${status.account}${where} but isn't running: ${status.problem ?? "no reason found"}`
  return [head, bootLine(status), `Log: ${status.logHint}`]
}

const bootLine = (status: DesktopStatus): string => {
  if (status.startsAtBoot) return "It starts at boot."
  if (status.startAtBootHint !== undefined)
    return `It starts at boot once this account lingers: ${status.startAtBootHint}`

  return "It starts when the Codevisor server starts, not by itself at boot."
}

const agreed = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions,
  question: string
): Promise<boolean> => {
  if (options.yes === true) return true
  if (deps.isInteractive) return deps.confirm(question)

  deps.error(question)
  deps.error("Run this in a terminal to answer, or pass --yes.")
  return false
}

const replaceOldDesktop = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus,
  options: DesktopCommandOptions
): Promise<DesktopStatus | undefined> => {
  if (status.oldDesktop === undefined) return status

  const question =
    "An older desktop runs as root on this machine. Replace it? Everything open in it will close."
  if (!(await agreed(deps, options, question))) return undefined

  deps.log("==> Removing the older desktop")
  return asAdministrator(deps, server, status, {
    what: "Removing the older desktop",
    path: "/replace-old",
    commands: status.oldDesktop.removal
  })
}

const installWhatIsMissing = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus
): Promise<DesktopStatus | undefined> => {
  if (status.missing.length === 0) return status
  if (status.install === undefined) {
    deps.error("Codevisor doesn't know how to install packages on this system.")
    deps.error(`Install these, then run setup again: ${status.missing.join(", ")}`)
    deps.error("(TigerVNC 1.12 or newer for Xvnc, Xfce, xclip, dbus and python3.)")
    return undefined
  }

  deps.log("==> Installing Xfce and TigerVNC (about 640 MB)")
  const equipped = await asAdministrator(deps, server, status, {
    what: "Installing packages",
    path: "/packages",
    commands: status.install
  })
  if (equipped === undefined || equipped.missing.length === 0) return equipped

  deps.error(`Still missing after the install: ${equipped.missing.join(", ")}`)
  return undefined
}

const asAdministrator = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus,
  step: AdministratorStep
): Promise<DesktopStatus | undefined> => {
  if (status.sudo === "passwordless") return server.ask("POST", step.path, installMs)

  const prefix = deps.isRoot ? [] : ["sudo"]
  const canRunHere = deps.isRoot || (status.sudo === "password" && deps.isInteractive)
  if (!canRunHere) {
    deps.error(`${step.what} needs an administrator. Ask one to run:`)
    for (const command of step.commands) deps.error(`  ${command.join(" ")}`)
    deps.error("then run `codevisor desktop setup` again.")
    return undefined
  }

  for (const command of step.commands) {
    const [program, ...args] = [...prefix, ...command]
    deps.log(`    ${[...prefix, ...command].join(" ")}`)
    if ((await deps.execInteractive(program!, args)) === 0) continue

    deps.error(`${step.what} failed.`)
    return undefined
  }
  return server.ask("GET", "", quickMs)
}
