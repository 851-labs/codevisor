import type { DesktopStatus, ScreenStatus } from "@codevisor/api"

import { waylandIsNotShared } from "../desktop/screen-share.js"

export const screenStatusLines = (status: DesktopStatus): ReadonlyArray<string> => {
  const screen = status.screen
  if (screen === undefined) return []
  if (screen.state === "none") return notSharedLines(screen)
  if (screen.state === "running")
    return [`The screen${where(screen)} is shared as ${status.account}.`]
  if (screen.state === "waiting")
    return [
      `The screen is set up to be shared, but ${status.account} isn't logged in at it${whoIs(screen)}.`
    ]

  return [`The screen is set up to be shared but isn't: ${screen.problem ?? "no reason found"}`]
}

export const describeScreen = (status: DesktopStatus, screen: ScreenStatus): string => {
  if (screen.session !== undefined)
    return `${status.account} is logged in at this machine's screen${where(screen)}`
  if (screen.others.length > 0)
    return `${screen.others.join(" and ")} ${isOrAre(screen)} logged in at this machine's screen`

  return "nobody is logged in at this machine's screen"
}

const notSharedLines = (screen: ScreenStatus): ReadonlyArray<string> => {
  if (screen.session === undefined) return []
  if (screen.session === "wayland")
    return [`This machine's screen isn't shared. ${waylandIsNotShared}`]

  return ["This machine's screen isn't shared. Share it with: codevisor desktop setup --screen"]
}

const where = (screen: ScreenStatus): string =>
  screen.display === undefined ? "" : ` (${sessionName(screen)}display ${screen.display})`

const sessionNames: ReadonlyMap<string, string> = new Map([
  ["x11", "X11, "],
  ["wlroots", "Wayland, "]
])

const sessionName = (screen: ScreenStatus): string => sessionNames.get(screen.session ?? "") ?? ""

const whoIs = (screen: ScreenStatus): string => {
  if (screen.others.length === 0) return ""

  return ` (${screen.others.join(" and ")} ${isOrAre(screen)})`
}

const isOrAre = (screen: ScreenStatus): string => (screen.others.length === 1 ? "is" : "are")
