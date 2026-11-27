import { setTimeout as wait } from "node:timers/promises"

import { fileVNCDesktops } from "../routes/vnc-desktops.js"
import type { VNCDesktops } from "../server-context-types.js"
import { type DesktopManager, makeDesktopManager } from "./desktop-manager.js"
import { systemDesktopSystem } from "./desktop-system.js"
import { makeScreenShare, type ScreenShare } from "./screen-share.js"

export interface LinuxDesktops {
  readonly desktops: VNCDesktops
  readonly desktop: DesktopManager | undefined
  readonly screen: ScreenShare | undefined
  readonly desktopResumed: Promise<void>
}

export interface LinuxDesktopsOptions {
  readonly dataDir: string
  readonly logsDir: string
  readonly cli: string
}

const desktopResumeLimitMs = 15_000
const followScreenEveryMs = 3000
const unreferenced = { ref: false }

export const linuxDesktops = (options: LinuxDesktopsOptions): LinuxDesktops => {
  if (process.platform !== "linux") return withoutLinux(options.dataDir)

  const { dataDir, logsDir } = options
  const system = systemDesktopSystem()
  const relayed: { desktops?: VNCDesktops } = {}
  const changed = (): void => relayed.desktops?.relays?.recheck()
  const screen = makeScreenShare({ system, dataDir, logsDir, changed })
  const desktops = fileVNCDesktops(dataDir, {
    viewerJoined: (display) => {
      if (display.screen === true) void screen.viewerJoined()
    }
  })
  relayed.desktops = desktops
  const desktop = makeDesktopManager({
    system,
    dataDir,
    logsDir,
    runner: {
      program: process.execPath,
      args: [options.cli, "desktop", "run", "--data-dir", dataDir]
    },
    changed
  })
  followTheScreen(screen)
  return { desktops, desktop, screen, desktopResumed: resumed(desktop) }
}

const withoutLinux = (dataDir: string): LinuxDesktops => ({
  desktops: fileVNCDesktops(dataDir),
  desktop: undefined,
  screen: undefined,
  desktopResumed: Promise.resolve()
})

const resumed = (desktop: DesktopManager): Promise<void> =>
  Promise.race([
    desktop.resume().catch(() => undefined),
    wait(desktopResumeLimitMs, undefined, unreferenced)
  ])

const followTheScreen = (screen: ScreenShare): void => {
  let isFollowing = false
  const follow = (): void => {
    if (isFollowing) return

    isFollowing = true
    void screen
      .follow()
      .catch(() => undefined)
      .finally(() => {
        isFollowing = false
      })
  }
  follow()
  setInterval(follow, followScreenEveryMs).unref()
}
