import { execFile } from "node:child_process"
import { readdir, rm } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { IOS_DEVELOPMENT_BUNDLE_IDENTIFIER } from "./dev-layout.ts"

export const MACOS_DEVELOPMENT_BUNDLE_IDENTIFIER = "com.851labs.Codevisor.Development"

export interface AppStateSystem {
  readonly home: string
  readonly userDirectories: () => Promise<ReadonlyArray<string>>
  readonly run: (command: string, args: ReadonlyArray<string>) => Promise<unknown>
}

const exec = promisify(execFile)
const commandTimeoutMilliseconds = 30_000
const libraryFolders = [
  "Application Support",
  "Caches",
  "Caches/com.apple.nsurlsessiond/Downloads",
  "HTTPStorages",
  "Preferences",
  "Saved Application State",
  "WebKit"
]
const userDirectoryVariables = ["DARWIN_USER_CACHE_DIR", "DARWIN_USER_TEMP_DIR"]

export function developmentBundleIdentifiers(instanceHash: string): Array<string> {
  return [
    `${MACOS_DEVELOPMENT_BUNDLE_IDENTIFIER}.${instanceHash}`,
    `${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}.${instanceHash}`
  ]
}

export async function purgeDevelopmentAppState(
  instanceHash: string,
  system: AppStateSystem = nativeSystem
): Promise<ReadonlyArray<string>> {
  const identifiers = developmentBundleIdentifiers(instanceHash)
  for (const identifier of identifiers) await forgetRegistrations(identifier, system)

  const removed: Array<string> = []
  for (const folder of await stateFolders(system)) {
    for (const path of await entriesOwnedBy(folder, identifiers)) {
      await rm(path, { recursive: true, force: true })
      removed.push(path)
    }
  }
  return removed
}

async function forgetRegistrations(identifier: string, system: AppStateSystem): Promise<void> {
  const registrations: ReadonlyArray<[string, ReadonlyArray<string>]> = [
    ["/usr/bin/defaults", ["delete", identifier]],
    ["/usr/bin/tccutil", ["reset", "All", identifier]],
    ["/usr/bin/security", ["delete-generic-password", "-s", browserKeychainService(identifier)]]
  ]
  for (const [command, args] of registrations) await system.run(command, args).catch(() => {})
}

function browserKeychainService(identifier: string): string {
  return `${identifier}.browser.safe-storage`
}

async function stateFolders(system: AppStateSystem): Promise<Array<string>> {
  return [
    ...libraryFolders.map((folder) => join(system.home, "Library", folder)),
    ...(await system.userDirectories())
  ]
}

async function entriesOwnedBy(
  folder: string,
  identifiers: ReadonlyArray<string>
): Promise<Array<string>> {
  const names = await readdir(folder).catch(() => [])
  return names
    .filter((name) => identifiers.some((identifier) => belongsTo(name, identifier)))
    .map((name) => join(folder, name))
}

function belongsTo(name: string, identifier: string): boolean {
  return name === identifier || name.startsWith(`${identifier}.`)
}

async function darwinUserDirectories(): Promise<Array<string>> {
  if (process.platform !== "darwin") return []

  const directories: Array<string> = []
  for (const variable of userDirectoryVariables) {
    const { stdout } = await exec("/usr/bin/getconf", [variable])
    if (stdout.trim().length > 0) directories.push(stdout.trim())
  }
  return directories
}

const nativeSystem: AppStateSystem = {
  home: homedir(),
  userDirectories: darwinUserDirectories,
  run: (command, args) => exec(command, [...args], { timeout: commandTimeoutMilliseconds })
}
