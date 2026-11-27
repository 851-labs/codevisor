import type { DesktopStatus, ScreenStatus } from "@codevisor/api"

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
  if (screen.others.length > 0) return `${screen.others.join(" and ")} at this machine's screen`

  return "nobody is logged in at this machine's screen"
}

const notSharedLines = (screen: ScreenStatus): ReadonlyArray<string> =>
  screen.session === undefined
    ? []
    : ["This machine's screen isn't shared. Share it with: codevisor desktop setup --screen"]

const where = (screen: ScreenStatus): string =>
  screen.display === undefined ? "" : ` (${sessionName(screen)}display ${screen.display})`

const sessionName = (screen: ScreenStatus): string => (screen.session === "x11" ? "X11, " : "")

const whoIs = (screen: ScreenStatus): string => {
  if (screen.others.length === 0) return ""

  return ` (${screen.others.join(" and ")} ${screen.others.length === 1 ? "is" : "are"})`
}
