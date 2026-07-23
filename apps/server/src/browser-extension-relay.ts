import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { homedir } from "node:os"
import { spawn, spawnSync } from "node:child_process"
import { dirname, join, relative, sep } from "node:path"
import { fileURLToPath } from "node:url"
import type WebSocket from "ws"
import { CdpConnection } from "./browser-cdp.js"

export const CODEVISOR_BROWSER_EXTENSION_ID = "clemkifaacpllomplgomnkbeoiindbhl"
export const CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL = `https://chromewebstore.google.com/detail/${CODEVISOR_BROWSER_EXTENSION_ID}`

export const browserExtensionPath = (
  options: {
    readonly moduleDirectory?: string
    readonly workingDirectory?: string
  } = {}
): string | undefined => {
  const here = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  return [
    join(here, "..", "resources", "browser-extension"),
    // Release runtimes copy the compiled entrypoints to the runtime root while
    // preserving resources under apps/server. This path must be relative to
    // the module, not process.cwd(): LaunchServices starts the macOS app in /.
    join(here, "apps", "server", "resources", "browser-extension"),
    join(workingDirectory, "apps", "server", "resources", "browser-extension"),
    join(workingDirectory, "resources", "browser-extension")
  ].find((candidate) => existsSync(join(candidate, "manifest.json")))
}

export interface BrowserExtensionInstallation {
  readonly bundled: boolean
  readonly installed: boolean
  readonly installationState: "installed" | "not_installed" | "unknown"
  readonly profiles: ReadonlyArray<string>
}

const chromeRoots = (home: string): ReadonlyArray<string> =>
  process.platform === "darwin"
    ? [
        join(home, "Library", "Application Support", "Google", "Chrome"),
        join(home, "Library", "Application Support", "Chromium"),
        join(home, "Library", "Application Support", "BraveSoftware", "Brave-Browser"),
        join(home, "Library", "Application Support", "Microsoft Edge")
      ]
    : process.platform === "linux"
      ? [
          join(home, ".config", "google-chrome"),
          join(home, ".config", "chromium"),
          join(home, ".config", "BraveSoftware", "Brave-Browser"),
          join(home, ".config", "microsoft-edge")
        ]
      : []

const profileHasExtension = (profile: string): boolean | undefined => {
  if (existsSync(join(profile, "Extensions", CODEVISOR_BROWSER_EXTENSION_ID))) return true
  let inaccessible = false
  for (const file of ["Preferences", "Secure Preferences"]) {
    const path = join(profile, file)
    if (!existsSync(path)) continue
    try {
      const preferences = JSON.parse(readFileSync(path, "utf8")) as {
        extensions?: { settings?: Record<string, unknown> }
      }
      if (preferences.extensions?.settings?.[CODEVISOR_BROWSER_EXTENSION_ID] !== undefined)
        return true
    } catch {
      inaccessible = true
    }
  }
  return inaccessible ? undefined : false
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
  const installationState =
    profiles.length > 0 ? "installed" : unknown ? "unknown" : "not_installed"
  return {
    bundled: browserExtensionPath() !== undefined,
    installed: installationState === "installed",
    installationState,
    profiles
  }
}

export const chromeBrowserAvailable = (): boolean =>
  process.platform === "darwin"
    ? existsSync("/Applications/Google Chrome.app") ||
      existsSync(join(homedir(), "Applications", "Google Chrome.app"))
    : process.platform === "linux"
      ? [
          "/usr/bin/google-chrome-stable",
          "/usr/bin/google-chrome",
          "/usr/bin/chromium-browser",
          "/usr/bin/chromium",
          "/snap/bin/chromium"
        ].some(existsSync)
      : false

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
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
    name: string
    description: string
    icons?: Record<string, string>
    action?: { default_title?: string; default_icon?: Record<string, string> }
  }
  const worktreeName = branding.worktreeName?.trim()
  const name =
    worktreeName === undefined || worktreeName === "" ? "Codevisor" : `Codevisor (${worktreeName})`
  manifest.name = name
  manifest.description = "Control Chrome with Codevisor."
  manifest.icons = { ...extensionIconFiles }
  manifest.action = {
    ...manifest.action,
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
    if (existsSync(generated))
      cpSync(generated, join(extension, "icons", destination), { force: true })
  }
}

const zipCrcTable = Array.from({ length: 256 }, (_, index) => {
  let value = index
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
  }
  return value >>> 0
})

const crc32 = (data: Buffer): number => {
  let value = 0xffffffff
  for (const byte of data) value = zipCrcTable[(value ^ byte) & 0xff]! ^ (value >>> 8)
  return (value ^ 0xffffffff) >>> 0
}

const extensionFiles = (directory: string): ReadonlyArray<string> => {
  const files: string[] = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === ".DS_Store") continue
    const path = join(directory, entry.name)
    if (entry.isDirectory()) files.push(...extensionFiles(path))
    else if (entry.isFile()) files.push(path)
  }
  return files
}

const extensionArchiveName = (extension: string): string => {
  const manifest = JSON.parse(readFileSync(join(extension, "manifest.json"), "utf8")) as {
    name?: string
  }
  const name = (manifest.name ?? "Codevisor").replaceAll(/[/:\\]/g, "-").trim()
  return `${name === "" ? "Codevisor" : name}.zip`
}

export const browserExtensionArchivePath = (extension: string): string =>
  join(dirname(extension), extensionArchiveName(extension))

/// Writes a portable, store-only ZIP without relying on a system `zip`
/// executable. The prepared extension is tiny, and avoiding a platform
/// dependency keeps the drag-to-install artifact available on Linux servers
/// as well as the macOS app.
export const createBrowserExtensionArchive = (extension: string): string => {
  if (!existsSync(join(extension, "manifest.json"))) {
    throw new Error("The Codevisor Chrome extension is missing")
  }
  const localParts: Buffer[] = []
  const centralParts: Buffer[] = []
  let localOffset = 0
  const fixedDosTime = 0
  const fixedDosDate = (40 << 9) | (1 << 5) | 1 // 2020-01-01

  for (const file of [...extensionFiles(extension)].sort()) {
    const name = relative(extension, file).split(sep).join("/")
    const nameBytes = Buffer.from(name, "utf8")
    const data = readFileSync(file)
    const checksum = crc32(data)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0x0800, 6)
    local.writeUInt16LE(0, 8)
    local.writeUInt16LE(fixedDosTime, 10)
    local.writeUInt16LE(fixedDosDate, 12)
    local.writeUInt32LE(checksum, 14)
    local.writeUInt32LE(data.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(nameBytes.length, 26)
    local.writeUInt16LE(0, 28)
    localParts.push(local, nameBytes, data)

    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(0x0314, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0x0800, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt16LE(fixedDosTime, 12)
    central.writeUInt16LE(fixedDosDate, 14)
    central.writeUInt32LE(checksum, 16)
    central.writeUInt32LE(data.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(nameBytes.length, 28)
    central.writeUInt16LE(0, 30)
    central.writeUInt16LE(0, 32)
    central.writeUInt16LE(0, 34)
    central.writeUInt16LE(0, 36)
    central.writeUInt32LE(0, 38)
    central.writeUInt32LE(localOffset, 42)
    centralParts.push(central, nameBytes)
    localOffset += local.length + nameBytes.length + data.length
  }

  const centralDirectory = Buffer.concat(centralParts)
  const end = Buffer.alloc(22)
  const entryCount = centralParts.length / 2
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entryCount, 8)
  end.writeUInt16LE(entryCount, 10)
  end.writeUInt32LE(centralDirectory.length, 12)
  end.writeUInt32LE(localOffset, 16)
  end.writeUInt16LE(0, 20)

  const archive = browserExtensionArchivePath(extension)
  const temporary = `${archive}.tmp-${process.pid.toString()}`
  rmSync(temporary, { force: true })
  writeFileSync(temporary, Buffer.concat([...localParts, centralDirectory, end]), { mode: 0o600 })
  renameSync(temporary, archive)
  return archive
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
  cpSync(source, extension, { recursive: true, force: true })
  applyExtensionBranding(extension, branding)
  const relay = new URL("/v1/browser-use/extension/socket", serverBaseUrl)
  relay.protocol = relay.protocol === "https:" ? "wss:" : "ws:"
  writeFileSync(
    join(extension, "relay-config.js"),
    `globalThis.CODEVISOR_RELAY = ${JSON.stringify(relay.toString())}\n`,
    { mode: 0o600 }
  )
  createBrowserExtensionArchive(extension)
  return extension
}

interface DevelopmentInstallerOptions {
  readonly platform?: NodeJS.Platform
  readonly chromePath?: string
  readonly launch?: (command: string, args: ReadonlyArray<string>) => void
}

const launchDetached = (command: string, args: ReadonlyArray<string>): void => {
  const child = spawn(command, [...args], { stdio: "ignore", detached: true })
  child.unref()
}

export const openBrowserExtensionDevelopmentInstaller = (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): void => {
  openBrowserExtensionDevelopmentPage(extension, options)
  openBrowserExtensionDevelopmentFolder(extension, options)
}

const requireBrowserExtension = (extension: string): void => {
  if (!existsSync(join(extension, "manifest.json"))) {
    throw new Error("The Codevisor Chrome extension is missing")
  }
}

export const openBrowserExtensionDevelopmentFolder = (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): void => {
  requireBrowserExtension(extension)
  const platform = options.platform ?? process.platform
  const launch = options.launch ?? launchDetached
  if (platform === "darwin") {
    launch("open", ["-a", "Finder", extension])
    return
  }
  if (platform === "linux") {
    launch("xdg-open", [extension])
    return
  }
  throw new Error(`Development extension setup is unavailable on ${platform}`)
}

export const openBrowserExtensionDevelopmentPage = (
  extension: string,
  options: DevelopmentInstallerOptions = {}
): void => {
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
    launch("open", ["-b", "com.google.Chrome", "chrome://extensions/"])
    return
  }
  if (platform === "linux") {
    const browser = ["google-chrome-stable", "google-chrome", "chromium-browser", "chromium"].find(
      (name) => spawnSync("which", [name], { stdio: "ignore" }).status === 0
    )
    launch(browser ?? "xdg-open", ["chrome://extensions/"])
    return
  }
  throw new Error(`Development extension setup is unavailable on ${platform}`)
}

export const openBrowserExtensionWebStore = (options: DevelopmentInstallerOptions = {}): void => {
  const platform = options.platform ?? process.platform
  const launch = options.launch ?? launchDetached
  if (platform === "darwin") {
    const chrome =
      options.chromePath ??
      (existsSync("/Applications/Google Chrome.app")
        ? "/Applications/Google Chrome.app"
        : join(homedir(), "Applications", "Google Chrome.app"))
    if (!existsSync(chrome)) throw new Error("Google Chrome is not installed")
    launch("open", ["-b", "com.google.Chrome", CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL])
    return
  }
  if (platform === "linux") {
    const browser = ["google-chrome-stable", "google-chrome", "chromium-browser", "chromium"].find(
      (name) => spawnSync("which", [name], { stdio: "ignore" }).status === 0
    )
    launch(browser ?? "xdg-open", [CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL])
    return
  }
  throw new Error(`Chrome Web Store setup is unavailable on ${platform}`)
}

export interface BrowserExtensionRelay {
  readonly connect: () => Promise<CdpConnection>
  readonly accept: (socket: WebSocket) => void
  readonly connected: () => boolean
  readonly onConnectionChange: (listener: (connected: boolean) => void) => () => void
  readonly close: () => Promise<void>
}

export const makeBrowserExtensionRelay = (): BrowserExtensionRelay => {
  let active: { readonly socket: WebSocket; readonly connection: CdpConnection } | undefined
  const waiters = new Set<(connection: CdpConnection) => void>()
  const listeners = new Set<(connected: boolean) => void>()
  let closed = false
  const notify = (connected: boolean) => {
    for (const listener of listeners) listener(connected)
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
      const previous = active
      const connection = CdpConnection.fromSocket(socket)
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
