import { execFile } from "node:child_process"
import { lstat, readdir, readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join, sep } from "node:path"

import { withPriority } from "./low-priority.js"

/// Xcode keeps state for a checkout outside the checkout: build output in
/// ~/Library/Developer/Xcode/DerivedData keyed by the project's path, and
/// simulators in CoreSimulator. Deleting a worktree left all of it behind --
/// tens of gigabytes per machine, for paths that no longer exist.
///
/// Only artifacts provably tied to a worktree path are touched: DerivedData by
/// the `WorkspacePath` Xcode records in its `info.plist`, and simulators by the
/// `codevisor-owner.json` marker `scripts/ios-simulator-owner.mjs` writes into
/// the device folder. Friendly device names are never trusted, because worktree
/// names are recycled across projects and over time. Shared caches
/// (`ModuleCache.noindex` and friends) have no `info.plist` and are skipped.

export interface XcodeArtifactHost {
  readonly derivedDataRoot: string
  readonly simulatorDevicesRoot: string
  readonly simctl: (args: ReadonlyArray<string>) => Promise<void>
}

/// The real Xcode locations, or undefined off macOS where there is no Xcode.
/* v8 ignore start -- the real system boundary; tests inject a host. */
export const systemXcodeArtifactHost = (): XcodeArtifactHost | undefined =>
  process.platform !== "darwin"
    ? undefined
    : {
        derivedDataRoot: join(homedir(), "Library/Developer/Xcode/DerivedData"),
        simulatorDevicesRoot: join(homedir(), "Library/Developer/CoreSimulator/Devices"),
        simctl: (args) =>
          new Promise((resolve, reject) => {
            execFile("/usr/bin/xcrun", ["simctl", ...args], { timeout: 120_000 }, (error) =>
              error === null ? resolve() : reject(error)
            )
          })
      }
/* v8 ignore stop */

const simulatorMarkerFormat = "codevisor-ios-simulator-v1"

const within = (path: string, directory: string): boolean =>
  path === directory || path.startsWith(directory + sep)

const exists = (path: string): Promise<boolean> =>
  lstat(path).then(
    () => true,
    () => false
  )

const entries = (directory: string): Promise<ReadonlyArray<string>> =>
  readdir(directory).catch(() => [])

const decodeXml = (text: string): string =>
  text
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&")

/// Xcode writes DerivedData's `info.plist` as XML.
const derivedDataWorkspacePath = (plist: string): string | undefined => {
  const match = /<key>WorkspacePath<\/key>\s*<string>([^<]*)<\/string>/.exec(plist)
  // The group always participates in a match.
  return match === null ? undefined : decodeXml(String(match[1]))
}

interface DerivedDataFolder {
  readonly path: string
  readonly workspacePath: string
}

const derivedDataFolders = async (root: string): Promise<ReadonlyArray<DerivedDataFolder>> => {
  const folders = await Promise.all(
    (await entries(root)).map(async (entry): Promise<DerivedDataFolder | undefined> => {
      const path = join(root, entry)
      const plist = await readFile(join(path, "info.plist"), "utf8").catch(() => undefined)
      const workspacePath = plist === undefined ? undefined : derivedDataWorkspacePath(plist)
      return workspacePath === undefined ? undefined : { path, workspacePath }
    })
  )
  return folders.filter((folder) => folder !== undefined)
}

interface OwnedSimulator {
  readonly udid: string
  readonly repoRoot: string
}

const ownedSimulators = async (root: string): Promise<ReadonlyArray<OwnedSimulator>> => {
  const devices = await Promise.all(
    (await entries(root)).map(async (udid): Promise<OwnedSimulator | undefined> => {
      // A missing or corrupt marker means the device is not ours.
      const marker = await readFile(join(root, udid, "codevisor-owner.json"), "utf8")
        .then(
          (text) =>
            JSON.parse(text) as Partial<Record<"format" | "udid" | "repoRoot", unknown>> | null
        )
        .catch(() => undefined)
      // A marker copied into another device's folder does not own it.
      return marker?.format === simulatorMarkerFormat &&
        marker.udid === udid &&
        typeof marker.repoRoot === "string"
        ? { udid, repoRoot: marker.repoRoot }
        : undefined
    })
  )
  return devices.filter((device) => device !== undefined)
}

/// Deletes at background priority: a DerivedData folder can be gigabytes and
/// nobody waits on it.
const purge = (path: string): Promise<void> =>
  new Promise((resolve) => {
    const command = withPriority("/bin/rm", ["-rf", "--", path], "background")
    execFile(command.command, [...command.args], () => resolve())
  })

const deleteSimulator = async (host: XcodeArtifactHost, udid: string): Promise<void> => {
  // Booted devices refuse deletion; shutting down an already-stopped one fails
  // harmlessly. Deletion fails when the worktree's own simulator owner noticed
  // the removal and deleted its device first.
  await host.simctl(["shutdown", udid]).catch(() => undefined)
  await host.simctl(["delete", udid]).catch(() => undefined)
}

const deleteArtifacts = async (
  host: XcodeArtifactHost,
  derivedData: ReadonlyArray<DerivedDataFolder>,
  simulators: ReadonlyArray<OwnedSimulator>
): Promise<void> => {
  await Promise.all([
    ...derivedData.map((folder) => purge(folder.path)),
    ...simulators.map((device) => deleteSimulator(host, device.udid))
  ])
}

/// Deletes the DerivedData and simulators belonging to a removed worktree.
/// Never rejects: every step swallows its own failure, and anything left
/// behind is caught by the boot sweep.
export const removeWorktreeXcodeArtifacts = async (
  worktreeDir: string,
  host: XcodeArtifactHost
): Promise<void> => {
  const [derivedData, simulators] = await Promise.all([
    derivedDataFolders(host.derivedDataRoot),
    ownedSimulators(host.simulatorDevicesRoot)
  ])
  await deleteArtifacts(
    host,
    derivedData.filter((folder) => within(folder.workspacePath, worktreeDir)),
    simulators.filter((device) => within(device.repoRoot, worktreeDir))
  )
}

const missing = async <T>(
  items: ReadonlyArray<T>,
  path: (item: T) => string
): Promise<ReadonlyArray<T>> => {
  const gone = await Promise.all(items.map(async (item) => !(await exists(path(item)))))
  return items.filter((_, index) => gone[index])
}

/// Catches whatever removal missed (a crash, a worktree deleted by hand, state
/// from before this cleanup existed):
/// - DerivedData for projects under `worktreesRoot` that no longer exist. The
///   user's own projects elsewhere are never touched.
/// - Codevisor-marked simulators whose checkout no longer exists.
/// - Simulators whose runtime was removed, which can never boot again.
export const sweepStaleXcodeArtifacts = async (
  worktreesRoot: string,
  host: XcodeArtifactHost
): Promise<void> => {
  const [derivedData, simulators] = await Promise.all([
    derivedDataFolders(host.derivedDataRoot),
    ownedSimulators(host.simulatorDevicesRoot)
  ])
  await deleteArtifacts(
    host,
    await missing(
      derivedData.filter((folder) => within(folder.workspacePath, worktreesRoot)),
      (folder) => folder.workspacePath
    ),
    await missing(simulators, (device) => device.repoRoot)
  )
  await host.simctl(["delete", "unavailable"]).catch(() => undefined)
}
