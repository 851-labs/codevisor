import type { DesktopSystem } from "./desktop-system.js"

export type SessionKind = "x11" | "wlroots" | "wayland"

export interface GraphicalSession {
  readonly kind: SessionKind
  readonly process: number
  readonly display?: string
  readonly env: Readonly<Record<string, string>>
}

export type SessionSystem = Pick<DesktopSystem, "uid" | "readText" | "listFolder">

export interface SessionSearch {
  readonly ignoreDisplay?: string | undefined
  readonly lookFirstAt?: number | undefined
}

export const ownGraphicalSession = (
  system: SessionSystem,
  search: SessionSearch = {}
): GraphicalSession | undefined => {
  const known = search.lookFirstAt === undefined ? undefined : sessionOf(system, search.lookFirstAt)
  if (known !== undefined && isWanted(known, search)) return known

  const found = processIds(system)
    .map((pid) => sessionOf(system, pid))
    .filter((session) => session !== undefined && isWanted(session, search))
  return found.find((session) => session?.env["DBUS_SESSION_BUS_ADDRESS"] !== undefined) ?? found[0]
}

export const accountsAtTheScreen = async (
  system: Pick<DesktopSystem, "run">
): Promise<ReadonlyArray<string> | undefined> => {
  const seated = await seatedAccounts(system)
  if (seated !== undefined && seated.length > 0) return seated

  return (await loggedInOnADisplay(system)) ?? seated
}

const carried = [
  "DISPLAY",
  "XAUTHORITY",
  "WAYLAND_DISPLAY",
  "XDG_RUNTIME_DIR",
  "DBUS_SESSION_BUS_ADDRESS",
  "SWAYSOCK",
  "HYPRLAND_INSTANCE_SIGNATURE"
]
const wlrootsMarks = ["SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE"]
const codevisorsMark = "CODEVISOR_DESKTOP_DISPLAY"
const greeters = new Set(["lightdm", "gdm", "sddm", "Debian-gdm", "greeter"])

const processIds = (system: SessionSystem): ReadonlyArray<number> =>
  system
    .listFolder("/proc")
    .filter((name) => /^\d+$/.test(name))
    .map(Number)

const sessionOf = (system: SessionSystem, pid: number): GraphicalSession | undefined => {
  if (ownerOf(system, pid) !== system.uid) return undefined

  const env = environmentOf(system.readText(`/proc/${pid}/environ`))
  const kind = kindOf(env)
  if (kind === undefined || isNotAtASeat(env)) return undefined

  return {
    kind,
    process: pid,
    ...(env["DISPLAY"] === undefined ? {} : { display: env["DISPLAY"] }),
    env: Object.fromEntries(carried.flatMap((name) => keptValue(env, name)))
  }
}

const keptValue = (
  env: Readonly<Record<string, string>>,
  name: string
): ReadonlyArray<readonly [string, string]> => {
  const value = env[name]
  return value === undefined ? [] : [[name, value]]
}

const isWanted = (session: GraphicalSession, search: SessionSearch): boolean =>
  session.display === undefined || session.display !== search.ignoreDisplay

const isNotAtASeat = (env: Readonly<Record<string, string>>): boolean =>
  (env["XDG_SEAT"] ?? "") === "" || env[codevisorsMark] !== undefined

const kindOf = (env: Readonly<Record<string, string>>): SessionKind | undefined => {
  if (env["WAYLAND_DISPLAY"] !== undefined)
    return wlrootsMarks.some((mark) => env[mark] !== undefined) ? "wlroots" : "wayland"

  return env["DISPLAY"] === undefined ? undefined : "x11"
}

const ownerOf = (system: SessionSystem, pid: number): number | undefined => {
  const uid = /^Uid:\s+(\d+)/m.exec(system.readText(`/proc/${pid}/status`) ?? "")?.[1]
  return uid === undefined ? undefined : Number(uid)
}

const environmentOf = (text: string | undefined): Readonly<Record<string, string>> =>
  Object.fromEntries(
    (text ?? "")
      .split("\0")
      .map((pair) => [pair.slice(0, pair.indexOf("=")), pair.slice(pair.indexOf("=") + 1)] as const)
      .filter(([name]) => name !== "")
  )

const seatedAccounts = async (
  system: Pick<DesktopSystem, "run">
): Promise<ReadonlyArray<string> | undefined> => {
  const listed = await system.run("loginctl", ["list-sessions", "--no-legend"])
  if (listed.code !== 0) return undefined

  const ids = listed.output
    .split("\n")
    .map((line) => line.trim().split(/\s+/)[0] ?? "")
    .filter((id) => id !== "")
  const accounts = await Promise.all(ids.map((id) => seatedAccountOf(system, id)))
  return unique(accounts.filter((account) => account !== undefined))
}

const seatedAccountOf = async (
  system: Pick<DesktopSystem, "run">,
  session: string
): Promise<string | undefined> => {
  const shown = await system.run("loginctl", [
    "show-session",
    session,
    "-p",
    "Name",
    "-p",
    "Seat",
    "-p",
    "Class",
    "-p",
    "Remote",
    "-p",
    "State"
  ])
  const fields = new Map(
    shown.output.split("\n").map((line) => {
      const [name = "", ...value] = line.trim().split("=")
      return [name, value.join("=")] as const
    })
  )
  const isAtTheScreen =
    shown.code === 0 &&
    (fields.get("Seat") ?? "") !== "" &&
    fields.get("Class") === "user" &&
    fields.get("Remote") !== "yes" &&
    fields.get("State") !== "closing"
  return isAtTheScreen ? fields.get("Name") : undefined
}

const loggedInOnADisplay = async (
  system: Pick<DesktopSystem, "run">
): Promise<ReadonlyArray<string> | undefined> => {
  const listed = await system.run("who", [])
  if (listed.code !== 0) return undefined

  return unique(
    listed.output
      .split("\n")
      .map((line) => line.trim().split(/\s+/))
      .filter((fields) => fields.some((field) => /^\(?:\d/.test(field)))
      .map((fields) => fields[0] ?? "")
      .filter((account) => account !== "" && !greeters.has(account))
  )
}

const unique = (names: ReadonlyArray<string>): ReadonlyArray<string> => [...new Set(names)]
