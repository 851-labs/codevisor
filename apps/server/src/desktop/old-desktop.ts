import type { DesktopSystem } from "./desktop-system.js"

export type RootCommand = ReadonlyArray<string>

export interface OldRootDesktop {
  readonly units: ReadonlyArray<string>
  readonly removal: ReadonlyArray<RootCommand>
}

const unitFile = "/etc/systemd/system/vncserver@.service"
const enabledFolder = "/etc/systemd/system/multi-user.target.wants"
const ours = "Codevisor desktop"
const instance = /^vncserver@\d+\.service$/

export const oldDesktop = (system: DesktopSystem): OldRootDesktop | undefined => {
  if (system.readText(unitFile)?.includes(ours) !== true) return undefined

  const units = system.listFolder(enabledFolder).filter((name) => instance.test(name))
  return {
    units,
    removal: [
      ...units.map((unit) => ["systemctl", "disable", "--now", unit]),
      ["rm", "-f", unitFile],
      ["systemctl", "daemon-reload"]
    ]
  }
}
