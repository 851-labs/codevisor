import type { DesktopSystem } from "./desktop-system.js"

export type RootCommand = ReadonlyArray<string>

export interface OldRootDesktop {
  readonly units: ReadonlyArray<string>
  readonly removal: ReadonlyArray<RootCommand>
}

const unitFile = "/etc/systemd/system/vncserver@.service"
const enabledFolder = "/etc/systemd/system/multi-user.target.wants"
const ours = "Codevisor desktop"
const instance = /^vncserver@(\d+)\.service$/
const rootXServer = /^root\s+(\d+)\s+\S*X(?:tiger)?vnc\s+:(\d+)(?:\s|$)/

export const oldDesktop = async (system: DesktopSystem): Promise<OldRootDesktop | undefined> => {
  if (system.readText(unitFile)?.includes(ours) !== true) return undefined

  const units = [...new Set([...enabledInstances(system), ...(await loadedInstances(system))])]
  return {
    units: units.toSorted(),
    removal: [
      ...units.toSorted().map((unit) => ["systemctl", "disable", "--now", unit]),
      ["rm", "-f", unitFile],
      ["systemctl", "daemon-reload"]
    ]
  }
}

export const oldDesktopLeftovers = async (
  system: DesktopSystem,
  old: OldRootDesktop
): Promise<ReadonlyArray<string>> => {
  const displays = new Set(old.units.map((unit) => instance.exec(unit)?.[1]))
  const processes = await system.run("ps", ["-eo", "user=,pid=,args="])
  return processes.output
    .split("\n")
    .map((line) => rootXServer.exec(line.trim()))
    .filter((found) => found !== null && displays.has(found[2]))
    .map((found) => `a root X server on :${found![2]} (pid ${found![1]})`)
}

const enabledInstances = (system: DesktopSystem): ReadonlyArray<string> =>
  system.listFolder(enabledFolder).filter((name) => instance.test(name))

const loadedInstances = async (system: DesktopSystem): Promise<ReadonlyArray<string>> => {
  const listed = await system.run("systemctl", [
    "list-units",
    "--all",
    "--plain",
    "--no-legend",
    "vncserver@*.service"
  ])
  return listed.output
    .split("\n")
    .map((line) => line.trim().split(/\s+/)[0] ?? "")
    .filter((name) => instance.test(name))
}
