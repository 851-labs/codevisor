import type { DesktopSudo } from "@codevisor/api"

import type { DesktopSystem } from "./desktop-system.js"
import type { RootCommand } from "./old-desktop.js"

export const DESKTOP_PROGRAMS = [
  "Xvnc",
  "startxfce4",
  "xfconf-query",
  "dbus-run-session",
  "xclip",
  "python3"
] as const

const aptPackages = [
  "tigervnc-standalone-server",
  "tigervnc-common",
  "xfce4",
  "xfce4-terminal",
  "dbus-x11",
  "xclip",
  "python3",
  "fonts-dejavu-core",
  "adwaita-icon-theme"
]

const aptFamily = new Set(["debian", "ubuntu"])
const aptLockWaitSeconds = 600
const updateTries = aptLockWaitSeconds / 10
const updateUntilTheListsLockIsFree = `for try in $(seq ${updateTries}); do out=$(apt-get update -q 2>&1) && exit 0; echo "$out"; echo "$out" | grep -q "Could not get lock" || exit 1; sleep 10; done; exit 1`
const plainWord = /^[A-Za-z0-9_@%+=:,./-]+$/

const shellWord = (word: string): string =>
  plainWord.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`
const installTimeoutMs = 20 * 60 * 1000
const outputTailLines = 30

export interface OsRelease {
  readonly name: string
  readonly ids: ReadonlyArray<string>
}

export const osRelease = (system: DesktopSystem): OsRelease => {
  const fields = new Map<string, string>()
  for (const line of (system.readText("/etc/os-release") ?? "").split("\n")) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line.trim())
    if (match !== null) fields.set(match[1]!, unquoted(match[2]!))
  }
  return {
    name: fields.get("PRETTY_NAME") ?? fields.get("NAME") ?? "this system",
    ids: [fields.get("ID") ?? "", ...(fields.get("ID_LIKE") ?? "").split(/\s+/)].filter(
      (id) => id !== ""
    )
  }
}

export const missingPrograms = async (system: DesktopSystem): Promise<ReadonlyArray<string>> => {
  const found = await Promise.all(DESKTOP_PROGRAMS.map((program) => hasProgram(system, program)))
  return DESKTOP_PROGRAMS.filter((_, index) => !found[index])
}

export const hasProgram = async (system: DesktopSystem, program: string): Promise<boolean> =>
  (await system.run("sh", ["-c", 'command -v "$1"', "sh", program])).code === 0

export const installCommands = async (
  system: DesktopSystem,
  release: OsRelease
): Promise<ReadonlyArray<RootCommand> | undefined> => {
  const usesApt = release.ids.some((id) => aptFamily.has(id))
  if (!usesApt || !(await hasProgram(system, "apt-get"))) return undefined

  const quietly = ["env", "DEBIAN_FRONTEND=noninteractive"]
  const lockWait = `DPkg::Lock::Timeout=${aptLockWaitSeconds}`
  return [
    [...quietly, "sh", "-c", updateUntilTheListsLockIsFree],
    [
      ...quietly,
      "apt-get",
      "-o",
      lockWait,
      "install",
      "-y",
      "-q",
      "--no-install-recommends",
      ...aptPackages
    ]
  ]
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
    const [program, ...args] = system.uid === 0 ? command : ["sudo", "-n", ...command]
    const ran = await system.run(program!, args, installTimeoutMs)
    if (ran.code !== 0) return { ok: false, output: tail(ran.output) }
  }
  return { ok: true, output: "" }
}

const tail = (output: string): string =>
  output.trimEnd().split("\n").slice(-outputTailLines).join("\n")

const unquoted = (value: string): string => value.replace(/^["']|["']$/g, "")
