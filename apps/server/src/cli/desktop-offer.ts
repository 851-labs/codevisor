import { join } from "node:path"

import { installPlan, osRelease } from "../desktop/desktop-packages.js"
import { type DesktopCliDeps, desktopSetupCommand, desktopStatusIfAnswered } from "./desktop.js"
import type { CommandOptions } from "./support.js"

export interface DesktopOfferDeps extends DesktopCliDeps {
  readonly answer: (question: string) => Promise<boolean | undefined>
}

const later = "codevisor desktop setup"
const declined = "desktop-declined"
const setupFailed = "desktop-setup-failed"

const noted = (deps: DesktopCliDeps, mark: string): void => {
  try {
    deps.writeTextFile(join(deps.dataDir, mark), "\n")
  } catch {
    return
  }
}

const setUpNow = async (deps: DesktopCliDeps, options: CommandOptions): Promise<boolean> => {
  try {
    return (await desktopSetupCommand(deps, options)) === 0
  } catch {
    return false
  }
}

const hasNothingToOffer = async (
  deps: DesktopCliDeps,
  options: CommandOptions
): Promise<boolean> => {
  const found = await desktopStatusIfAnswered(deps, options)
  if (found === undefined) return true

  const isSetUp = found.state === "running" || found.state === "stopped"
  if (isSetUp && found.unmanaged !== true) return true
  if (found.sudo === "none" && !deps.isRoot) return true

  const plan = await installPlan(deps.system, osRelease(deps.system))
  return found.missing.length > 0 && plan === undefined
}

export const offerDesktop = async (
  deps: DesktopOfferDeps,
  options: CommandOptions = {}
): Promise<void> => {
  if (deps.system.platform !== "linux" || !deps.isInteractive) return
  if (deps.readTextFile(join(deps.dataDir, declined)) !== undefined) return
  if (await hasNothingToOffer(deps, options)) return

  deps.log("")
  deps.log("This machine can have a desktop that you watch and control from Codevisor.")
  const wanted = await deps.answer("Set up a desktop?")
  if (wanted === undefined) return
  if (!wanted) {
    noted(deps, declined)
    deps.log(`No desktop set up. Add one any time with: ${later}`)
    return
  }
  if (await setUpNow(deps, options)) return

  noted(deps, setupFailed)
  deps.error(`The desktop wasn't set up. Try again with: ${later}`)
}
