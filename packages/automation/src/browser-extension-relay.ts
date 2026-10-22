import { spawn, spawnSync } from "node:child_process"
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"

import { CdpConnection, type CdpSocket } from "./browser-cdp.js"
import { createBrowserExtensionArchive } from "./browser-extension-archive.js"
import { findServerResource, type ServerResourceOptions } from "./server-resources.js"
import { expectRecord, recordOrEmpty } from "./unknown-values.js"

export {
  browserExtensionArchivePath,
  createBrowserExtensionArchive
} from "./browser-extension-archive.js"

export const CODEVISOR_BROWSER_EXTENSION_ID = "clemkifaacpllomplgomnkbeoiindbhl"
export const CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL = `https://chromewebstore.google.com/detail/${CODEVISOR_BROWSER_EXTENSION_ID}`

export const browserExtensionPath = (options: ServerResourceOptions = {}): string | undefined =>
  findServerResource("browser-extension", options, (candidate) =>
    existsSync(join(candidate, "manifest.json"))
  )

export interface BrowserExtensionInstallation {
  readonly bundled: boolean
  readonly installed: boolean
  readonly installationState: "installed" | "not_installed" | "unknown"
  readonly profiles: ReadonlyArray<string>
}

const chromeRoots = (home: string): ReadonlyArray<string> => {
  if (process.platform === "darwin")
    return [
      join(home, "Library", "Application Support", "Google", "Chrome"),
      join(home, "Library", "Application Support", "Chromium"),
      join(home, "Library", "Application Support", "BraveSoftware", "Brave-Browser"),
      join(home, "Library", "Application Support", "Microsoft Edge")
    ]
  if (process.platform === "linux")
    return [
      join(home, ".config", "google-chrome"),
      join(home, ".config", "chromium"),
      join(home, ".config", "BraveSoftware", "Brave-Browser"),
      join(home, ".config", "microsoft-edge")
    ]
  return []
}

const profileHasExtension = (profile: string): boolean | undefined => {
  if (existsSync(join(profile, "Extensions", CODEVISOR_BROWSER_EXTENSION_ID))) return true
  let inaccessible = false
  for (const file of ["Preferences", "Secure Preferences"]) {
    const path = join(profile, file)
    if (!existsSync(path)) continue
    try {
      const preferences: unknown = JSON.parse(readFileSync(path, "utf8"))
      const settings = recordOrEmpty(recordOrEmpty(recordOrEmpty(preferences).extensions).settings)
      if (settings[CODEVISOR_BROWSER_EXTENSION_ID] !== undefined) return true
    } catch {
      inaccessible = true
    }
  }
  return inaccessible ? undefined : false
}

const extensionInstallationState = (profiles: ReadonlyArray<string>, unknown: boolean) => {
  if (profiles.length > 0) return "installed"
  if (unknown) return "unknown"
  return "not_installed"
}

export const browserExtensionInstallation = (home = homedir()): BrowserExtensionInstallation => {
  const profiles: string[] = []
  let unknown = false
  for (const root of chromeRoots(home)) {
    if (!existsSync(root)) continue
    let names: string[]
    try {
      names = readdirSync(root)
    } catch {
      unknown = true
      continue
    }
    for (const name of names) {
      if (name !== "Default" && !name.startsWith("Profile ")) continue
      const profile = join(root, name)
      const installed = profileHasExtension(profile)
      if (installed === true) profiles.push(profile)
      else if (installed === undefined) unknown = true
    }
  }
  const installationState = extensionInstallationState(profiles, unknown)
  return {
    bundled: browserExtensionPath() !== undefined,
    installed: installationState === "installed",
    installationState,
    profiles
  }
}

export const chromeBrowserAvailable = (): boolean => {
  if (process.platform === "darwin")
    return (
      existsSync("/Applications/Google Chrome.app") ||
      existsSync(join(homedir(), "Applications", "Google Chrome.app"))
    )
  if (process.platform === "linux")
    return [
      "/usr/bin/google-chrome-stable",
      "/usr/bin/google-chrome",
      "/usr/bin/chromium-browser",
      "/usr/bin/chromium",
      "/snap/bin/chromium"
    ].some(existsSync)
  return false
}

export interface BrowserExtensionBranding {
  readonly worktreeName?: string | undefined
  readonly iconDirectory?: string | undefined
}

const extensionIconFiles = {
  "16": "icons/16.png",
  "32": "icons/32.png",
  "128": "icons/128.png"
} as const

const applyExtensionBranding = (extension: string, branding: BrowserExtensionBranding): void => {
  const manifestPath = join(extension, "manifest.json")
  const manifest: Record<string, unknown> = {
    ...expectRecord(JSON.parse(readFileSync(manifestPath, "utf8")), "Extension manifest")
  }
  const worktreeName = branding.worktreeName?.trim()
  const name =
    worktreeName === undefined || worktreeName === "" ? "Codevisor" : `Codevisor (${worktreeName})`
  manifest.name = name
  manifest.description = "Control Chrome with Codevisor."
  manifest.icons = { ...extensionIconFiles }
  manifest.action = {
    ...recordOrEmpty(manifest.action),
    default_title: name,
    default_icon: { ...extensionIconFiles }
  }
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 })

  const iconDirectory = branding.iconDirectory
  if (iconDirectory === undefined) return
  const generatedIcons = {
    "16.png": "icon_16x16.png",
    "32.png": "icon_16x16@2x.png",
    "128.png": "icon_128x128.png"
  } as const
  for (const [destination, source] of Object.entries(generatedIcons)) {
    const generated = join(iconDirectory, source)
    if (existsSync(generated)) copyFileSync(generated, join(extension, "icons", destination))
  }
}

export const prepareBrowserExtension = (
  dataDir: string,
  serverBaseUrl: string,
  branding: BrowserExtensionBranding = {
    worktreeName: process.env.CODEVISOR_DEV_WORKTREE,
    iconDirectory: process.env.CODEVISOR_DEV_EXTENSION_ICON_DIR
  }
): string => {
  const source = browserExtensionPath()
  if (source === undefined) throw new Error("The Codevisor Chrome extension is missing")
  const extension = join(dataDir, "browser", "extension")
  mkdirSync(dirname(extension), { recursive: true, mode: 0o700 })
  const staged = `${extension}.next-${process.pid}-${(stagedExtensions += 1)}`
  copyDirectory(source, staged)
  applyExtensionBranding(staged, branding)
  const relay = new URL("/v1/browser-use/extension/socket", serverBaseUrl)
  relay.protocol = relay.protocol === "https:" ? "wss:" : "ws:"
  writeFileSync(
    join(staged, "relay-config.js"),
    `globalThis.CODEVISOR_RELAY = ${JSON.stringify(relay.toString())}\n`,
    { mode: 0o600 }
  )
  replaceDirectory(staged, extension)
  createBrowserExtensionArchive(extension)
  return extension
}

let stagedExtensions = 0

const copyDirectory = (source: string, target: string): void => {
  mkdirSync(target, { recursive: true })
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const from = join(source, entry.name)
    const to = join(target, entry.name)
    if (entry.isDirectory()) copyDirectory(from, to)
    else copyFileSync(from, to)
  }
}

const replaceDirectory = (staged: string, target: string): void => {
  const stale = `${target}.stale-${process.pid}-${stagedExtensions}`
  if (existsSync(target)) renameSync(target, stale)
  renameSync(staged, target)
  const parent = dirname(target)
  for (const entry of readdirSync(parent)) {
    if (!entry.startsWith(`${basename(target)}.stale-`)) continue
    try {
      rmSync(join(parent, entry), { force: true, recursive: true })
    } catch {}
  }
}

interface DevelopmentInstallerOptions {
  readonly platform?: NodeJS.Platform
  readonly chromePath?: string
  readonly launch?: (command: string, args: ReadonlyArray<string>) => Promise<void>
}

const launchDetached = (command: string, args: ReadonlyArray<string>): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, [...args], { stdio: "ignore", detached: true })
    child.unref()
    child.on("error", (cause) => reject(new Error(`Could not open ${command}: ${cause.message}`)))
    child.once("spawn", () => resolve())
  })

export const openBrowserExtensionDevelopmentInstaller = async (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): Promise<void> => {
  await openBrowserExtensionDevelopmentPage(extension, options)
  await openBrowserExtensionDevelopmentFolder(extension, options)
}

const requireBrowserExtension = (extension: string): void => {
  if (!existsSync(join(extension, "manifest.json"))) {
    throw new Error("The Codevisor Chrome extension is missing")
  }
}

export const openBrowserExtensionDevelopmentFolder = async (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): Promise<void> => {
  requireBrowserExtension(extension)
  const platform = options.platform ?? process.platform
  const launch = options.launch ?? launchDetached
  if (platform === "darwin") {
    await launch("open", ["-a", "Finder", extension])
    return
  }
  if (platform === "linux") {
    await launch("xdg-open", [extension])
    return
  }
  throw new Error(`Development extension setup is unavailable on ${platform}`)
}

export const openBrowserExtensionDevelopmentPage = async (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): Promise<void> => {
  requireBrowserExtension(extension)
  const platform = options.platform ?? process.platform
  const launch = options.launch ?? launchDetached
  if (platform === "darwin") {
    const chrome =
      options.chromePath ??
      (existsSync("/Applications/Google Chrome.app")
        ? "/Applications/Google Chrome.app"
        : join(homedir(), "Applications", "Google Chrome.app"))
    if (!existsSync(chrome)) throw new Error("Google Chrome is not installed")
    await launch("open", ["-b", "com.google.Chrome", "chrome://extensions/"])
    return
  }
  if (platform === "linux") {
    const browser = ["google-chrome-stable", "google-chrome", "chromium-browser", "chromium"].find(
      (name) => spawnSync("which", [name], { stdio: "ignore" }).status === 0
    )
    await launch(browser ?? "xdg-open", ["chrome://extensions/"])
    return
  }
  throw new Error(`Development extension setup is unavailable on ${platform}`)
}

export const openBrowserExtensionWebStore = async (
  options: DevelopmentInstallerOptions = {}
): Promise<void> => {
  const platform = options.platform ?? process.platform
  const launch = options.launch ?? launchDetached
  if (platform === "darwin") {
    const chrome =
      options.chromePath ??
      (existsSync("/Applications/Google Chrome.app")
        ? "/Applications/Google Chrome.app"
        : join(homedir(), "Applications", "Google Chrome.app"))
    if (!existsSync(chrome)) throw new Error("Google Chrome is not installed")
    await launch("open", ["-b", "com.google.Chrome", CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL])
    return
  }
  if (platform === "linux") {
    const browser = ["google-chrome-stable", "google-chrome", "chromium-browser", "chromium"].find(
      (name) => spawnSync("which", [name], { stdio: "ignore" }).status === 0
    )
    await launch(browser ?? "xdg-open", [CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL])
    return
  }
  throw new Error(`Chrome Web Store setup is unavailable on ${platform}`)
}

export interface BrowserExtensionSocket extends CdpSocket {
  close(code?: number, reason?: string): void
}

export const EXTENSION_READY_PROBE_MS = 1_000

const extensionReady = async (connection: CdpConnection): Promise<boolean> => {
  while (!connection.closed) {
    try {
      await connection.sendOnce("Target.getTargets", {}, undefined, EXTENSION_READY_PROBE_MS)
      return true
    } catch (cause) {
      const timedOut =
        cause instanceof Error && cause.message.startsWith("Browser command timed out")
      if (!timedOut) return !connection.closed
    }
  }
  return false
}

export interface BrowserExtensionRelay {
  readonly connect: () => Promise<CdpConnection>
  readonly accept: (socket: BrowserExtensionSocket) => void
  readonly connected: () => boolean
  readonly onConnectionChange: (listener: (connected: boolean) => void) => () => void
  readonly close: () => Promise<void>
}

export const makeBrowserExtensionRelay = (): BrowserExtensionRelay => {
  let active:
    | { readonly socket: BrowserExtensionSocket; readonly connection: CdpConnection }
    | undefined
  const waiters = new Set<(connection: CdpConnection) => void>()
  const listeners = new Set<(connected: boolean) => void>()
  let closed = false
  const notify = (connected: boolean) => {
    for (const listener of listeners) listener(connected)
  }
  const activate = (socket: BrowserExtensionSocket, connection: CdpConnection) => {
    const previous = active
    const next = { socket, connection }
    active = next
    socket.once("close", () => {
      if (active !== next) return
      active = undefined
      notify(false)
    })
    for (const resolve of waiters) resolve(connection)
    waiters.clear()
    notify(true)
    if (previous !== undefined) void previous.connection.close().catch(() => undefined)
  }
  return {
    connect: () => {
      if (closed) throw new Error("Browser extension relay is closed")
      if (active !== undefined) return Promise.resolve(active.connection)
      return new Promise<CdpConnection>((resolve) => waiters.add(resolve))
    },
    accept: (socket) => {
      if (closed) {
        socket.close(1001, "Codevisor browser relay is closed")
        return
      }
      const connection = CdpConnection.fromSocket(socket)
      void extensionReady(connection).then((ready) => {
        if (ready && !closed) activate(socket, connection)
        else void connection.close().catch(() => undefined)
      })
    },
    connected: () => active !== undefined,
    onConnectionChange: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    close: async () => {
      closed = true
      waiters.clear()
      listeners.clear()
      const connection = active?.connection
      active = undefined
      if (connection !== undefined) await connection.close().catch(() => undefined)
    }
  }
}
