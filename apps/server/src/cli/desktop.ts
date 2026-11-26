import { DesktopStatus } from "@codevisor/api"
import { Schema } from "effect"

import {
  DESKTOP_PROGRAMS,
  type InstallPlan,
  installPlan,
  type OsRelease,
  osRelease,
  packageManagerFor,
  shellText
} from "../desktop/desktop-packages.js"
import type { DesktopSystem } from "../desktop/desktop-system.js"
import { oldDesktop, oldDesktopLeftovers, type RootCommand } from "../desktop/old-desktop.js"
import { resolvePort, routeFailure, type CliDeps, type CommandOptions } from "./support.js"

export interface DesktopCliDeps extends CliDeps {
  readonly isInteractive: boolean
  readonly confirm: (question: string) => Promise<boolean>
  readonly system: DesktopSystem
}

export interface DesktopCommandOptions extends CommandOptions {
  readonly yes?: boolean
}

interface AdministratorStep {
  readonly what: string
  readonly path: string
  readonly commands: ReadonlyArray<RootCommand>
}

const quickMs = 30_000
const startMs = 2 * 60 * 1000
const busyPollMs = 2000
const busyPolls = 30 * 30
const unansweredPollsAllowed = 5
const replaceOldQuestion =
  "An older desktop runs as root on this machine. Replace it? Everything open in it will close."
const replaceUnmanagedQuestion =
  "This machine has a desktop config that Codevisor didn't write. Replace it with a new desktop? A desktop it points at keeps running but is no longer shared."
const unshareQuestion =
  "The desktop shared from this machine wasn't set up by Codevisor. Stop sharing it? It keeps running; Codevisor only forgets it."
const notUnderstood =
  "The server's answer about the desktop wasn't understood. The server may be older or newer than this command."

export const desktopSetupCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const server = await desktopServer(deps, options)
  deps.log("==> Checking this machine")
  const found = await server.ask("GET", "", quickMs)
  if (found === undefined) return 1

  const release = osRelease(deps.system)
  deps.log(`    ${release.name}, ${describeState(found)}`)
  const plan = await installPlan(deps.system, release)
  if (found.missing.length > 0 && plan === undefined) {
    deps.error(installThemYourself(release, found.missing))
    return 1
  }

  const cleared = await replaceOldDesktop(deps, server, found, options)
  if (cleared === undefined) return 1

  const equipped = await installWhatIsMissing(deps, server, cleared, plan)
  if (equipped === undefined) return 1

  return startTheDesktop(deps, server, equipped, options)
}

export const desktopStatusCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const status = await (await desktopServer(deps, options)).ask("GET", "", quickMs)
  if (status === undefined) return 1

  for (const line of await statusLines(status, deps.system)) deps.log(line)
  return 0
}

export const desktopRemoveCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const server = await desktopServer(deps, options)
  const found = await server.ask("GET", "", quickMs)
  if (found === undefined) return 1
  if (found.unmanaged === true) return stopSharing(deps, server, options)

  const question = "Remove the desktop? This closes everything open in it."
  if (!(await agreed(deps, options, question))) return 1
  if ((await server.ask("DELETE", "", startMs)) === undefined) return 1

  deps.log("The desktop is removed. Its packages stay installed.")
  return 0
}

const stopSharing = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  options: DesktopCommandOptions
): Promise<number> => {
  if (!(await agreed(deps, options, unshareQuestion))) return 1
  if ((await server.ask("DELETE", "?unshare=1", startMs)) === undefined) return 1

  deps.log("The desktop is no longer shared. It wasn't Codevisor's, so it was left running.")
  return 0
}

interface DesktopServer {
  readonly ask: (
    method: string,
    path: string,
    timeoutMs: number
  ) => Promise<DesktopStatus | undefined>
  readonly peek: () => Promise<DesktopStatus | undefined>
}

const desktopServer = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions
): Promise<DesktopServer> => {
  const port = await resolvePort(deps, options.port)
  const url = `http://127.0.0.1:${port}/v1/desktop`
  return {
    ask: async (method, path, timeoutMs) => {
      const response = await deps.fetchJson(`${url}${path}`, { method, timeoutMs })
      const status = response?.status === 200 ? answered(response.body) : undefined
      if (status === undefined)
        deps.error(
          response?.status === 200 ? notUnderstood : printable(routeFailure(response, port))
        )
      return status
    },
    peek: async () => {
      const response = await deps.fetchJson(url, { timeoutMs: quickMs })
      return response?.status === 200 ? answered(response.body) : undefined
    }
  }
}

const controlCharacters = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu
const accountName = /^[a-z_][a-z0-9_.-]{0,31}\$?$/i
const knownPrograms = new Set<string>(DESKTOP_PROGRAMS)

const continued = "    | "

const printable = (text: string): string =>
  text
    .split("\n")
    .map((line) => line.replaceAll("\t", "  ").replace(controlCharacters, ""))
    .map((line, index) => (index === 0 ? line : `${continued}${line}`))
    .join("\n")

const decoded = (body: unknown): DesktopStatus | undefined => {
  try {
    return Schema.decodeUnknownSync(DesktopStatus)(body)
  } catch {
    return undefined
  }
}

const answered = (body: unknown): DesktopStatus | undefined => {
  const status = decoded(body)
  if (status === undefined) return undefined

  return {
    ...status,
    account: accountName.test(status.account) ? status.account : "the server's account",
    system: printable(status.system),
    missing: status.missing.filter((program) => knownPrograms.has(program)),
    logHint: printable(status.logHint),
    ...(status.problem === undefined ? {} : { problem: printable(status.problem) }),
    ...(status.busy === undefined ? {} : { busy: printable(status.busy) }),
    ...(status.failure === undefined ? {} : { failure: printable(status.failure) })
  }
}

const lingerCommand = (status: DesktopStatus): string =>
  `sudo loginctl enable-linger ${accountName.test(status.account) ? status.account : "<the server's account>"}`

const describeState = (status: DesktopStatus): string => {
  if (status.state === "running") return "a desktop is running"
  if (status.state === "stopped") return "a desktop is set up but not running"
  if (status.state === "outdated") return "a desktop set up for an older Codevisor"

  return "no desktop set up"
}

const statusLines = async (
  status: DesktopStatus,
  system: DesktopSystem
): Promise<ReadonlyArray<string>> => {
  const old = await oldDesktop(system)
  if (old === undefined) return stateLines(status)

  const units = old.units.join(", ") || "vncserver"
  return [
    ...stateLines(status),
    `An older desktop still runs as root (${units}). Replace it with: codevisor desktop setup`
  ]
}

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
  if (status.unitOwnedByAnother === true)
    return "It won't come back by itself once it stops: another Codevisor server on this account owns the desktop unit (codevisor-desktop.service)."
  if (status.startsAtBoot) return "It starts at boot."
  if (status.startAtBootHint !== undefined)
    return `It starts at boot once this account lingers: ${lingerCommand(status)}`

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
  const old = await oldDesktop(deps.system)
  if (old === undefined) return status
  if (!(await agreed(deps, options, replaceOldQuestion))) return undefined

  deps.log("==> Removing the older desktop")
  const cleared = await asAdministrator(deps, server, status, {
    what: "Removing the older desktop",
    path: "/replace-old",
    commands: old.removal
  })
  if (cleared === undefined) return undefined

  const left = await oldDesktopLeftovers(deps.system, old)
  if (left.length === 0) return cleared

  deps.error(`The older desktop is still running: ${left.join(", ")}.`)
  deps.error("Stop it, then run `codevisor desktop setup` again.")
  return undefined
}

const installWhatIsMissing = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus,
  plan: InstallPlan | undefined
): Promise<DesktopStatus | undefined> => {
  if (status.missing.length === 0) return status
  if (plan === undefined) {
    deps.error(installThemYourself(osRelease(deps.system), status.missing))
    return undefined
  }

  deps.log(`==> Installing Xfce and TigerVNC with ${plan.manager} (about ${plan.megabytes} MB)`)
  const equipped = await asAdministrator(deps, server, status, {
    what: "Installing packages",
    path: "/packages",
    commands: plan.commands
  })
  if (equipped === undefined || equipped.missing.length === 0) return equipped

  deps.error(`Still missing after the install: ${equipped.missing.join(", ")}`)
  return undefined
}

const startTheDesktop = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus,
  options: DesktopCommandOptions
): Promise<number> => {
  const alreadyOurs = status.keepsRunning === true
  const theirs = isSomeoneElses(status)
  if (theirs && !(await agreed(deps, options, replaceUnmanagedQuestion))) return 1
  if (!alreadyOurs) deps.log(`==> Starting the desktop as ${status.account}`)

  const started = await server.ask("POST", theirs ? "/start?replace=1" : "/start", startMs)
  if (started === undefined) return 1

  deps.log(
    alreadyOurs
      ? "==> The desktop is already running. Open it from this machine in Codevisor."
      : "==> The desktop is ready. Open it from this machine in Codevisor."
  )
  if (started.startAtBootHint !== undefined)
    deps.log(`    It starts at boot once this account lingers: ${lingerCommand(started)}`)
  return 0
}

const comesWith: Record<string, string> = {
  Xvnc: "Xvnc (TigerVNC 1.12 or newer)",
  startxfce4: "startxfce4 (Xfce)",
  "xfconf-query": "xfconf-query (Xfce)",
  "dbus-run-session": "dbus-run-session (dbus)"
}

const whyNotHere = (release: OsRelease): string => {
  const manager = packageManagerFor(release)
  if (manager === undefined)
    return "it only installs with apt on Debian and Ubuntu, dnf on Fedora, pacman on Arch and zypper on openSUSE"

  return `it would use ${manager}, which is missing here or can't change this system's files`
}

const installThemYourself = (release: OsRelease, missing: ReadonlyArray<string>): string =>
  [
    `Codevisor can't install what the desktop needs on ${release.name}: ${whyNotHere(release)}.`,
    `Install these yourself, then run \`codevisor desktop setup\` again: ${missing.map((program) => comesWith[program] ?? program).join(", ")}.`
  ].join("\n")

const isSomeoneElses = (status: DesktopStatus): boolean => status.unmanaged === true

const whenTheServerIsDone = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  begun: DesktopStatus | undefined
): Promise<DesktopStatus | undefined> => {
  let status = begun
  let unanswered = 0
  for (let poll = 0; status?.busy !== undefined && poll < busyPolls; poll += 1) {
    await deps.sleep(busyPollMs)
    const latest = await server.peek()
    unanswered = latest === undefined ? unanswered + 1 : 0
    if (unanswered > unansweredPollsAllowed) return server.ask("GET", "", quickMs)

    status = latest ?? status
  }
  if (status === undefined) return undefined

  const problem = status.busy === undefined ? status.failure : stillBusy(status.busy)
  if (problem === undefined) return status

  deps.error(problem)
  return undefined
}

const stillBusy = (what: string): string =>
  `${what} is still going on. Run \`codevisor desktop setup\` again when it is done.`

const asAdministrator = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus,
  step: AdministratorStep
): Promise<DesktopStatus | undefined> => {
  if (status.sudo === "passwordless")
    return whenTheServerIsDone(deps, server, await server.ask("POST", step.path, startMs))

  const prefix = deps.isRoot ? [] : ["sudo"]
  const canRunHere = deps.isRoot || (status.sudo === "password" && deps.isInteractive)
  if (!canRunHere) {
    deps.error(`${step.what} needs an administrator. Ask one to run:`)
    for (const command of step.commands) deps.error(`  ${shellText(command)}`)
    deps.error("then run `codevisor desktop setup` again.")
    return undefined
  }

  for (const command of step.commands) {
    const [program, ...args] = [...prefix, ...command]
    deps.log(`    ${shellText([...prefix, ...command])}`)
    if ((await deps.execInteractive(program!, args)) === 0) continue

    deps.error(`${step.what} failed.`)
    return undefined
  }
  return server.ask("GET", "", quickMs)
}
