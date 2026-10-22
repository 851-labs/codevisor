import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { delimiter, join } from "node:path"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import {
  ensureNativeHostSecret,
  nativeHostDirectory,
  nativeHostNameFor
} from "./browser-native-host.js"
import { requireServerResource } from "./server-resources.js"

export const NATIVE_MESSAGING_DIRECTORIES_ENV = "CODEVISOR_NATIVE_MESSAGING_DIRS"

export interface NativeHostInstallOptions {
  readonly dataDir: string
  readonly hostName: string
  readonly nodePath: string
  readonly hostScript: string
  readonly manifestDirectories: ReadonlyArray<string>
}

export interface NativeHostInstallation {
  readonly hostName: string
  readonly launcher: string
  readonly manifests: ReadonlyArray<string>
}

export interface ServerNativeHostOptions {
  readonly env: Readonly<Record<string, string | undefined>>
  readonly home: string
  readonly platform: NodeJS.Platform
}

export const installBrowserNativeHost = (
  options: NativeHostInstallOptions
): NativeHostInstallation => {
  ensureNativeHostSecret(options.dataDir)
  const launcher = writeLauncher(options)
  const manifest = hostManifest(options.hostName, launcher)
  const manifests = options.manifestDirectories.map((directory) =>
    writeManifest(directory, options.hostName, manifest)
  )
  return { hostName: options.hostName, launcher, manifests }
}

export const installServerNativeHost = (
  dataDir: string,
  { env, home, platform }: ServerNativeHostOptions
): NativeHostInstallation => {
  const hostScript = requireServerResource(
    "native-host/codevisor-native-host.mjs",
    "Codevisor native messaging host"
  )
  return installBrowserNativeHost({
    dataDir,
    hostName: nativeHostNameFor(env.CODEVISOR_DEV_WORKTREE),
    nodePath: process.execPath,
    hostScript,
    manifestDirectories: manifestDirectoriesFor(env, home, platform)
  })
}

export const browserNativeMessagingDirectories = (
  home: string,
  platform: NodeJS.Platform
): ReadonlyArray<string> =>
  browserUserDataRoots(home, platform)
    .filter((root) => existsSync(root))
    .map((root) => join(root, "NativeMessagingHosts"))

export const browserUserDataRoots = (
  home: string,
  platform: NodeJS.Platform
): ReadonlyArray<string> => {
  if (platform === "darwin") return macUserDataRoots(home)
  if (platform === "linux") return linuxUserDataRoots(home)
  return []
}

const macUserDataRoots = (home: string): ReadonlyArray<string> =>
  [
    "Google/Chrome",
    "Google/Chrome Beta",
    "Google/Chrome Dev",
    "Google/Chrome Canary",
    "Chromium",
    "BraveSoftware/Brave-Browser",
    "BraveSoftware/Brave-Browser-Beta",
    "BraveSoftware/Brave-Browser-Nightly",
    "Microsoft Edge",
    "Microsoft Edge Beta",
    "Microsoft Edge Dev",
    "Microsoft Edge Canary",
    "Arc/User Data",
    "Vivaldi"
  ].map((path) => join(home, "Library", "Application Support", path))

const linuxUserDataRoots = (home: string): ReadonlyArray<string> =>
  [
    "google-chrome",
    "google-chrome-beta",
    "google-chrome-unstable",
    "chromium",
    "BraveSoftware/Brave-Browser",
    "BraveSoftware/Brave-Browser-Beta",
    "BraveSoftware/Brave-Browser-Nightly",
    "microsoft-edge",
    "microsoft-edge-beta",
    "microsoft-edge-dev",
    "vivaldi"
  ].map((path) => join(home, ".config", path))

const manifestDirectoriesFor = (
  env: Readonly<Record<string, string | undefined>>,
  home: string,
  platform: NodeJS.Platform
): ReadonlyArray<string> => {
  const override = env[NATIVE_MESSAGING_DIRECTORIES_ENV]
  if (override !== undefined) return override.split(delimiter).filter((path) => path !== "")
  if (env.CODEVISOR_DEV_WORKTREE !== undefined) return []
  return browserNativeMessagingDirectories(home, platform)
}

const writeLauncher = (options: NativeHostInstallOptions): string => {
  const directory = nativeHostDirectory(options.dataDir)
  const launcher = join(directory, options.hostName)
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  writeIfChanged(launcher, launcherScript(options), 0o700)
  return launcher
}

const launcherScript = (options: NativeHostInstallOptions): string =>
  [
    "#!/bin/sh",
    `exec ${shellQuoted(options.nodePath)} ${shellQuoted(options.hostScript)} ${shellQuoted(options.dataDir)} "$@"`,
    ""
  ].join("\n")

const shellQuoted = (value: string): string => `'${value.replaceAll("'", `'\\''`)}'`

const hostManifest = (hostName: string, launcher: string): string =>
  `${JSON.stringify(
    {
      name: hostName,
      description: "Connects the Codevisor Chrome extension to the Codevisor app.",
      path: launcher,
      type: "stdio",
      allowed_origins: [`chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}/`]
    },
    null,
    2
  )}\n`

const writeManifest = (directory: string, hostName: string, manifest: string): string => {
  const path = join(directory, `${hostName}.json`)
  mkdirSync(directory, { recursive: true })
  writeIfChanged(path, manifest, 0o644)
  return path
}

const writeIfChanged = (path: string, contents: string, mode: number): void => {
  if (existsSync(path) && readFileSync(path, "utf8") === contents) return

  const staged = `${path}.next-${process.pid}`
  writeFileSync(staged, contents, { mode })
  renameSync(staged, path)
}
