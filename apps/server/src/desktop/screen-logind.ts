import type { DesktopSystem } from "./desktop-system.js"

export interface AtTheScreen {
  readonly account: string
  readonly type?: string
  readonly session?: string
  readonly display?: string
}

export type LogindSystem = Pick<DesktopSystem, "run" | "readText" | "listFolder">

export const accountsAtTheScreen = async (
  system: LogindSystem
): Promise<ReadonlyArray<AtTheScreen> | undefined> => {
  const seated = await seatedAccounts(system)
  if (seated !== undefined) return seated

  return loggedInOnADisplay(system)
}

export const processIds = (system: Pick<DesktopSystem, "listFolder">): ReadonlyArray<number> =>
  system
    .listFolder("/proc")
    .filter((name) => /^\d+$/.test(name))
    .map(Number)

export const isInSession = (
  system: Pick<DesktopSystem, "readText">,
  pid: number,
  session: string
): boolean => system.readText(`/proc/${pid}/cgroup`)?.includes(`/session-${session}.scope`) === true

const graphicalTypes = new Set(["x11", "wayland", "mir"])
const xServers = new Set(["Xorg", "Xorg.bin", "X"])
const greeters = new Set(["lightdm", "gdm", "sddm", "Debian-gdm", "greeter"])
const properties = ["Id", "Name", "Seat", "Class", "Remote", "State", "Type", "Display"]

const seatedAccounts = async (
  system: LogindSystem
): Promise<ReadonlyArray<AtTheScreen> | undefined> => {
  const listed = await system.run("loginctl", ["list-sessions", "--no-legend"])
  if (listed.code !== 0) return undefined

  const ids = listed.output
    .split("\n")
    .map((line) => line.trim().split(/\s+/)[0] ?? "")
    .filter((id) => id !== "")
  const accounts = await Promise.all(ids.map((id) => seatedAccountOf(system, id)))
  return uniqueAccounts(accounts.filter((account) => account !== undefined))
}

const seatedAccountOf = async (
  system: LogindSystem,
  session: string
): Promise<AtTheScreen | undefined> => {
  const shown = await system.run("loginctl", [
    "show-session",
    session,
    ...properties.flatMap((property) => ["-p", property])
  ])
  if (shown.code !== 0) return undefined

  const fields = fieldsOf(shown.output)
  const account = fields.get("Name") ?? ""
  if (account === "" || !isALocalSeatedLogin(fields)) return undefined

  const graphical = graphicalSide(system, fields)
  return graphical === undefined ? undefined : { account, ...graphical }
}

const isALocalSeatedLogin = (fields: ReadonlyMap<string, string>): boolean =>
  (fields.get("Seat") ?? "") !== "" &&
  fields.get("Class") === "user" &&
  fields.get("Remote") !== "yes" &&
  fields.get("State") !== "closing"

const graphicalSide = (
  system: LogindSystem,
  fields: ReadonlyMap<string, string>
): Omit<AtTheScreen, "account"> | undefined => {
  const session = fields.get("Id") ?? ""
  const type = fields.get("Type") ?? ""
  const display = fields.get("Display") ?? ""
  const known = {
    ...(session === "" ? {} : { session }),
    ...(display === "" ? {} : { display })
  }
  if (graphicalTypes.has(type)) return { type, ...known }
  if (type !== "tty" || session === "") return undefined

  const started = xServerStartedIn(system, session)
  if (started === undefined) return undefined

  return { type: "x11", ...known, ...(started === "" ? {} : { display: started }) }
}

const xServerStartedIn = (system: LogindSystem, session: string): string | undefined => {
  const server = processIds(system).find(
    (pid) =>
      xServers.has(system.readText(`/proc/${pid}/comm`)?.trim() ?? "") &&
      isInSession(system, pid, session)
  )
  if (server === undefined) return undefined

  const words = (system.readText(`/proc/${server}/cmdline`) ?? "").split("\0")
  return words.find((word) => /^:\d+$/.test(word)) ?? ""
}

const fieldsOf = (output: string): ReadonlyMap<string, string> =>
  new Map(
    output.split("\n").map((line) => {
      const [name = "", ...value] = line.trim().split("=")
      return [name, value.join("=")] as const
    })
  )

const loggedInOnADisplay = async (
  system: Pick<DesktopSystem, "run">
): Promise<ReadonlyArray<AtTheScreen> | undefined> => {
  const listed = await system.run("who", [])
  if (listed.code !== 0) return undefined

  const accounts = [
    ...new Set(
      listed.output
        .split("\n")
        .map((line) => line.trim().split(/\s+/))
        .filter((fields) => fields.some((field) => /^\(?:\d/.test(field)))
        .map((fields) => fields[0] ?? "")
        .filter((account) => account !== "" && !greeters.has(account))
    )
  ]
  return accounts.map((account) => ({ account }))
}

const uniqueAccounts = (found: ReadonlyArray<AtTheScreen>): ReadonlyArray<AtTheScreen> =>
  found.filter((entry, at) => found.findIndex((other) => other.account === entry.account) === at)
