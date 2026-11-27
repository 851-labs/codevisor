import type { DesktopStatus } from "@codevisor/api"

import { installPlan, osRelease } from "../desktop/desktop-packages.js"
import { someoneElseIsThere, waylandIsNotShared } from "../desktop/screen-share.js"
import { describeScreen } from "./desktop-screen-status.js"
import {
  asAdministrator,
  type DesktopCliDeps,
  type DesktopCommandOptions,
  type DesktopServer,
  desktopServer,
  quickMs,
  startMs
} from "./desktop.js"

const rerun = "codevisor desktop setup --screen"
const sessionsOnWayland = new Set(["wayland", "wlroots"])
const tooOld =
  "Codevisor on this machine is too old to share its screen. Update it, then run this again."

export const screenSetupCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const server = await desktopServer(deps, options)
  deps.log("==> Checking this machine")
  const found = await server.ask("GET", "?screen=1", quickMs)
  if (found === undefined) return 1
  if (found.screen === undefined) return refused(deps, tooOld)

  deps.log(`    ${osRelease(deps.system).name}, ${describeScreen(found, found.screen)}`)
  const isSomeoneElses = found.screen.session === undefined && found.screen.others.length > 0
  if (isSomeoneElses) return refused(deps, someoneElseIsThere(found.screen.others, found.account))
  if (sessionsOnWayland.has(found.screen.session ?? "")) return refused(deps, waylandIsNotShared)

  const equipped = await installWhatIsMissing(deps, server, found)
  if (equipped === undefined) return 1

  return shareTheScreen(deps, server)
}

export const screenRemoveCommand = async (
  deps: DesktopCliDeps,
  options: DesktopCommandOptions = {}
): Promise<number> => {
  const server = await desktopServer(deps, options)
  const found = await server.ask("GET", "", quickMs)
  if (found === undefined) return 1
  if (found.screen === undefined || found.screen.state === "none") {
    deps.log("This machine's screen isn't shared.")
    return 0
  }
  if ((await server.ask("DELETE", "/screen", startMs)) === undefined) return 1

  deps.log("The screen is no longer shared. Nothing on it was closed.")
  return 0
}

const setUpButNotShared = (problem: string | undefined): ReadonlyArray<string> => [
  `The screen is set up, but isn't shared yet: ${problem ?? "no reason found"}.`,
  "Codevisor tries again every 30 seconds. To undo the setup: codevisor desktop remove --screen"
]

const refused = (deps: DesktopCliDeps, ...lines: ReadonlyArray<string>): number => {
  for (const line of lines) deps.error(line)
  return 1
}

const installWhatIsMissing = async (
  deps: DesktopCliDeps,
  server: DesktopServer,
  status: DesktopStatus
): Promise<DesktopStatus | undefined> => {
  const missing = status.screen?.missing ?? []
  if (missing.length === 0) return status

  const plan = await installPlan(deps.system, osRelease(deps.system))
  if (plan === undefined) {
    deps.error(
      `Codevisor can't install packages on this system. Install these yourself, then run \`${rerun}\` again: ${missing.join(", ")} (TigerVNC's x0vncserver, and notify-send from libnotify).`
    )
    return undefined
  }

  deps.log(`==> Installing ${missing.join(" and ")} with ${plan.manager}`)
  const equipped = await asAdministrator(deps, server, status, {
    what: "Installing packages",
    path: "/screen/packages",
    commands: plan.screenCommands,
    rerun,
    progress: (answer) => answer.screen
  })
  const still = equipped?.screen?.missing ?? []
  if (equipped === undefined || still.length === 0) return equipped

  deps.error(`Still missing after the install: ${still.join(", ")}`)
  return undefined
}

const shareTheScreen = async (deps: DesktopCliDeps, server: DesktopServer): Promise<number> => {
  const shared = await server.ask("POST", "/screen", startMs)
  const screen = shared?.screen
  if (shared === undefined || screen === undefined) return 1
  if (screen.state === "stopped") return refused(deps, ...setUpButNotShared(screen.problem))

  deps.log(
    screen.state === "running"
      ? "==> The screen is shared. Open this machine in Codevisor and choose the display named Screen."
      : `==> Set up. The screen is shared whenever ${shared.account} is logged in at this machine, and nobody is right now.`
  )
  return 0
}
