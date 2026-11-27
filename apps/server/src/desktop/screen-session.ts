import type { DesktopSystem } from "./desktop-system.js"
import { WLROOTS_COMPOSITORS } from "./screen-commands.js"
import { isInSession, processIds } from "./screen-logind.js"

export { type AtTheScreen, accountsAtTheScreen } from "./screen-logind.js"

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
  readonly session?: string | undefined
  readonly display?: string | undefined
  readonly type?: string | undefined
}

export const ownGraphicalSession = (
  system: SessionSystem,
  search: SessionSearch = {}
): GraphicalSession | undefined => {
  const known =
    search.lookFirstAt === undefined ? undefined : candidate(system, search.lookFirstAt, search)
  const found =
    known !== undefined && fitsTheType(known, search.type)
      ? [known]
      : processIds(system).flatMap((pid) => candidate(system, pid, search) ?? [])
  const chosen = newestOf(system, withTheBus(ofTheSessionsType(found, search.type)))
  return chosen === undefined ? undefined : withItsCompositor(system, chosen)
}

const isWayland = (session: GraphicalSession): boolean =>
  session.env["WAYLAND_DISPLAY"] !== undefined

const fitsTheType = (session: GraphicalSession, type: string | undefined): boolean =>
  type !== "wayland" || isWayland(session)

const ofTheSessionsType = (
  found: ReadonlyArray<GraphicalSession>,
  type: string | undefined
): ReadonlyArray<GraphicalSession> => {
  if (type !== "wayland") return found

  const wayland = found.filter(isWayland)
  return wayland.length > 0 ? wayland : found
}

const withItsCompositor = (system: SessionSystem, chosen: GraphicalSession): GraphicalSession => {
  if (chosen.kind !== "wayland") return chosen

  const compositor = compositorBehind(system, chosen.process, chosen.env["WAYLAND_DISPLAY"])
  const isWlroots =
    compositor !== undefined &&
    ownerOf(system, compositor) === system.uid &&
    WLROOTS_COMPOSITORS.has(commOf(system, compositor))
  return isWlroots ? { ...chosen, kind: "wlroots" } : chosen
}

const deepestAncestry = 64

const compositorBehind = (
  system: SessionSystem,
  pid: number,
  wayland: string | undefined
): number | undefined => {
  let current = parentOf(system, pid)
  for (let step = 0; current !== undefined && current > 1 && step < deepestAncestry; step += 1) {
    if (WLROOTS_COMPOSITORS.has(commOf(system, current))) return current
    const env = environmentOf(system.readText(`/proc/${current}/environ`))
    if (env["WAYLAND_DISPLAY"] !== wayland) return current
    current = parentOf(system, current)
  }
  return undefined
}

const commOf = (system: SessionSystem, pid: number): string =>
  system.readText(`/proc/${pid}/comm`)?.trim() ?? ""

const parentOf = (system: SessionSystem, pid: number): number | undefined => {
  const parent = /^PPid:\s+(\d+)/m.exec(system.readText(`/proc/${pid}/status`) ?? "")?.[1]
  return parent === undefined ? undefined : Number(parent)
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
const x11Sockets = "/tmp/.X11-unix"
const startTimeField = 19

const candidate = (
  system: SessionSystem,
  pid: number,
  search: SessionSearch
): GraphicalSession | undefined => {
  if (ownerOf(system, pid) !== system.uid) return undefined

  const env = environmentOf(system.readText(`/proc/${pid}/environ`))
  const kind = kindOf(env)
  if (kind === undefined || env[codevisorsMark] !== undefined) return undefined
  if (sameDisplay(env["DISPLAY"], search.ignoreDisplay)) return undefined
  if (!belongs(system, pid, env, search)) return undefined

  const display = search.display ?? env["DISPLAY"]
  const kept = Object.fromEntries(carried.flatMap((name) => keptValue(env, name)))
  return {
    kind,
    process: pid,
    ...(display === undefined ? {} : { display }),
    env: display === undefined ? kept : { ...kept, DISPLAY: display }
  }
}

const belongs = (
  system: SessionSystem,
  pid: number,
  env: Readonly<Record<string, string>>,
  search: SessionSearch
): boolean => {
  if (search.session !== undefined)
    return isInSession(system, pid, search.session) && showsTheDisplay(env, search.display)
  if (search.display !== undefined)
    return sameDisplay(env["DISPLAY"], search.display) && isLive(system, env["DISPLAY"])
  if ((env["XDG_SEAT"] ?? "") === "") return false

  return env["WAYLAND_DISPLAY"] !== undefined || isLive(system, env["DISPLAY"])
}

const showsTheDisplay = (env: Readonly<Record<string, string>>, display?: string): boolean =>
  display === undefined || env["DISPLAY"] === undefined || sameDisplay(env["DISPLAY"], display)

export const sameDisplay = (one: string | undefined, other: string | undefined): boolean =>
  one !== undefined && other !== undefined && withoutScreen(one) === withoutScreen(other)

const withoutScreen = (display: string): string => display.replace(/^(:\d+)\.\d+$/, "$1")

const isLive = (system: SessionSystem, display: string | undefined): boolean => {
  const number = /^:(\d+)(\.\d+)?$/.exec(display ?? "")?.[1]
  return number !== undefined && system.listFolder(x11Sockets).includes(`X${number}`)
}

const withTheBus = (found: ReadonlyArray<GraphicalSession>): ReadonlyArray<GraphicalSession> => {
  const onTheBus = found.filter((session) => session.env["DBUS_SESSION_BUS_ADDRESS"] !== undefined)
  return onTheBus.length > 0 ? onTheBus : found
}

const newestOf = (
  system: SessionSystem,
  found: ReadonlyArray<GraphicalSession>
): GraphicalSession | undefined =>
  found.toSorted((one, other) => startOf(system, other.process) - startOf(system, one.process))[0]

const startOf = (system: SessionSystem, pid: number): number => {
  const stat = system.readText(`/proc/${pid}/stat`) ?? ""
  const afterName = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
  return Number(afterName[startTimeField]) || 0
}

const keptValue = (
  env: Readonly<Record<string, string>>,
  name: string
): ReadonlyArray<readonly [string, string]> => {
  const value = env[name]
  return value === undefined ? [] : [[name, value]]
}

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
