import type { DesktopSudo } from "@codevisor/api"

import type { DesktopSystem } from "./desktop-system.js"
import type { RootCommand } from "./old-desktop.js"
import {
  DESKTOP_PROGRAMS,
  type OsRelease,
  type PackageManager,
  packageFamilies,
  type ScreenCommands,
  SCREEN_NOTIFIER,
  SCREEN_PROGRAMS,
  type ScreenProgram,
  WLROOTS_SCREEN_PROGRAMS,
  X11_SCREEN_PROGRAMS
} from "./package-managers.js"
import {
  type Scraper,
  type ScreenKind,
  WLROOTS_COMPOSITORS,
  WLROOTS_SCRAPERS,
  X11_SCRAPERS
} from "./screen-commands.js"

export {
  DESKTOP_PROGRAMS,
  type OsRelease,
  SCREEN_PROGRAMS,
  type ScreenProgram
} from "./package-managers.js"

const plainWord = /^[A-Za-z0-9_@%+=:,./-]+$/

const shellWord = (word: string): string =>
  plainWord.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`
const mountFields = 4
const rootStepSeconds = 20 * 60
const killAfterSeconds = 30
const timeLimit = ["timeout", `--kill-after=${killAfterSeconds}`, String(rootStepSeconds)]
const giveUpMs = (rootStepSeconds + 2 * killAfterSeconds) * 1000
const outputTailLines = 30

export interface InstallPlan {
  readonly manager: PackageManager
  readonly megabytes: number
  readonly commands: ReadonlyArray<RootCommand>
  readonly screenCommands: ScreenCommands
}

export const osRelease = (system: DesktopSystem): OsRelease => {
  const fields = new Map<string, string>()
  for (const line of (system.readText("/etc/os-release") ?? "").split("\n")) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line.trim())
    if (match !== null) fields.set(match[1]!, unquoted(match[2]!))
  }
  const id = fields.get("ID") ?? ""
  return {
    name: fields.get("PRETTY_NAME") ?? fields.get("NAME") ?? "this system",
    id,
    ids: [id, ...(fields.get("ID_LIKE") ?? "").split(/\s+/)].filter((like) => like !== "")
  }
}

export const missingPrograms = async (system: DesktopSystem): Promise<ReadonlyArray<string>> => {
  const found = await Promise.all(DESKTOP_PROGRAMS.map((program) => hasProgram(system, program)))
  return DESKTOP_PROGRAMS.filter((_, index) => !found[index])
}

export interface ScreenPrograms {
  readonly scrapers: ReadonlyMap<ScreenKind, Scraper | undefined>
  readonly hasNotifier: boolean
}

export const screenPrograms = async (
  system: DesktopSystem,
  kinds: ReadonlyArray<ScreenKind>
): Promise<ScreenPrograms> => {
  const scrapers = new Map<ScreenKind, Scraper | undefined>()
  for (const kind of kinds) scrapers.set(kind, await scraperFor(system, kind))
  return { scrapers, hasNotifier: await hasProgram(system, SCREEN_NOTIFIER) }
}

export const knowsAbout = (found: ScreenPrograms, kinds: ReadonlyArray<ScreenKind>): boolean =>
  kinds.every((kind) => found.scrapers.has(kind))

const scraperFor = (system: DesktopSystem, kind: ScreenKind): Promise<Scraper | undefined> =>
  kind === "x11" ? x11Scraper(system) : wlrootsScraper(system)

const x11Scraper = async (system: DesktopSystem): Promise<Scraper | undefined> => {
  const program = await firstInstalled(system, X11_SCRAPERS)
  return program === undefined ? undefined : { program }
}

const wlrootsScraper = async (system: DesktopSystem): Promise<Scraper | undefined> => {
  const program = await firstInstalled(system, WLROOTS_SCRAPERS)
  if (program === undefined) return undefined

  const help = (await system.run(program, ["--help"])).output
  if (!help.includes("--unix-socket")) return { program, tooOld: await versionOf(system, program) }

  return { program, hasControlSocket: help.includes("--socket") }
}

const versionOf = async (system: DesktopSystem, program: string): Promise<string> => {
  const answer = (await system.run(program, ["--version"])).output
  return /^\S+:\s*(\S+)/.exec(answer.trim())?.[1] ?? "of this version"
}

export const missingFor = (
  found: ScreenPrograms,
  kinds: ReadonlyArray<ScreenKind>
): ReadonlyArray<ScreenProgram> => {
  const needed = new Set<ScreenProgram>(
    kinds.flatMap((kind) => (kind === "x11" ? X11_SCREEN_PROGRAMS : WLROOTS_SCREEN_PROGRAMS))
  )
  return SCREEN_PROGRAMS.filter((program) => needed.has(program) && isMissing(found, program))
}

const isMissing = (found: ScreenPrograms, program: ScreenProgram): boolean => {
  if (program === SCREEN_NOTIFIER) return !found.hasNotifier

  return found.scrapers.get(program === "wayvnc" ? "wlroots" : "x11") === undefined
}

const xSessions = "/usr/share/xsessions"

export const screenKindsOfTheMachine = async (
  system: DesktopSystem
): Promise<ReadonlyArray<ScreenKind>> => {
  const wlroots = await firstInstalled(system, [...WLROOTS_COMPOSITORS])
  const x11 =
    system.listFolder(xSessions).some((name) => name.endsWith(".desktop")) ||
    (await hasProgram(system, "Xorg"))
  const kinds: ReadonlyArray<ScreenKind> = [
    ...(x11 ? (["x11"] as const) : []),
    ...(wlroots === undefined ? [] : (["wlroots"] as const))
  ]
  return kinds.length === 0 ? ["x11"] : kinds
}

const firstInstalled = async (
  system: DesktopSystem,
  programs: ReadonlyArray<string>
): Promise<string | undefined> => {
  for (const program of programs) if (await hasProgram(system, program)) return program

  return undefined
}

export const hasProgram = async (system: DesktopSystem, program: string): Promise<boolean> =>
  (await system.run("sh", ["-c", 'command -v "$1"', "sh", program])).code === 0

export const packageManagerFor = (release: OsRelease): PackageManager | undefined =>
  packageFamilies.find((candidate) => candidate.serves(release))?.manager

const systemFilesAreReadOnly = (system: DesktopSystem): boolean => {
  const mounts = (system.readText("/proc/mounts") ?? "")
    .split("\n")
    .map((line) => line.split(" "))
    .filter((fields) => fields.length >= mountFields)
  const holding =
    mounts.findLast((fields) => fields[1] === "/usr") ??
    mounts.findLast((fields) => fields[1] === "/")
  return holding?.[3]?.split(",").includes("ro") === true
}

export const installPlan = async (
  system: DesktopSystem,
  release: OsRelease
): Promise<InstallPlan | undefined> => {
  const family = packageFamilies.find((candidate) => candidate.serves(release))
  if (family === undefined || systemFilesAreReadOnly(system)) return undefined
  if (!(await hasProgram(system, family.program))) return undefined

  return {
    manager: family.manager,
    megabytes: family.megabytes,
    commands: family.commands,
    screenCommands: family.screenCommands
  }
}

export const shellText = (command: RootCommand): string => command.map(shellWord).join(" ")

export const sudoKind = async (system: DesktopSystem): Promise<DesktopSudo> => {
  if (system.uid === 0) return "passwordless"
  if ((await system.run("sudo", ["-n", "true"])).code === 0) return "passwordless"
  if (await hasProgram(system, "sudo")) return "password"

  return "none"
}

export interface RootRun {
  readonly ok: boolean
  readonly output: string
}

export const runAsRoot = async (
  system: DesktopSystem,
  commands: ReadonlyArray<RootCommand>
): Promise<RootRun> => {
  for (const command of commands) {
    const asRoot = system.uid === 0 ? [] : ["sudo", "-n"]
    const [program, ...args] = [...asRoot, ...timeLimit, ...command]
    const ran = await system.run(program!, args, giveUpMs)
    if (ran.code !== 0) return { ok: false, output: tail(ran.output) }
  }
  return { ok: true, output: "" }
}

const tail = (output: string): string =>
  output.trimEnd().split("\n").slice(-outputTailLines).join("\n")

const unquoted = (value: string): string => value.replace(/^["']|["']$/g, "")
