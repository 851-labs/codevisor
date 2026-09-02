import { createHash } from "node:crypto"
import { cp, mkdir, rm } from "node:fs/promises"
import { homedir } from "node:os"
import { basename, join } from "node:path"

import { developmentLayout, iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import {
  colorFromHash,
  containsAnyPath,
  directoryIsEmpty,
  findAvailablePort,
  parsePort,
  pathExists
} from "./dev-shared.mjs"

/// Per-worktree identity of a dev rig: names, bundle identifiers, on-disk
/// layout, and the stable-but-scanned ports every process binds.

// Sanitize ambient Codevisor variables before anything inherits our env.
// This script is often launched from inside a running Codevisor instance
// (agent sessions, app terminals) whose server exports CODEVISOR_* state —
// e.g. CODEVISOR_APP_HOSTED=1 — which must never leak into the dev app or
// dev servers (a dev app that inherits APP_HOSTED thinks it manages its own
// server and hangs at "Starting Codevisor Server"). Only the documented
// dev-runner inputs survive.
const ambientAllowlist = new Set([
  "CODEVISOR_DEV_PORT",
  "HERDMAN_DEV_PORT",
  "CODEVISOR_DEV_WWW_PORT",
  "CODEVISOR_DEV_CLOUD_PORT",
  "CODEVISOR_DEV_DATA_DIR",
  "CODEVISOR_DEV_LOGS_DIR",
  "CODEVISOR_DEV_CACHE_DIR",
  "HERDMAN_DEV_DATA_DIR",
  "CODEVISOR_WORKTREES_ROOT",
  "CODEVISOR_DEV_CONTAINER_ENGINE",
  "HERDMAN_WORKTREES_ROOT",
  "CODEVISOR_REPOS_ROOT",
  "CODEVISOR_PLUGINS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACTS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN",
  "CODEVISOR_IOS_SIMULATOR",
  "CODEVISOR_VERSION",
  "HERDMAN_VERSION"
])

export function sanitizeAmbientEnvironment(environment) {
  for (const key of Object.keys(environment)) {
    if (
      (key.startsWith("CODEVISOR_") || key.startsWith("HERDMAN_")) &&
      !ambientAllowlist.has(key)
    ) {
      delete environment[key]
    }
  }
}

export async function resolveDevelopmentInstance(repoRoot, environment) {
  const worktreeName = basename(repoRoot)
  const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
  const developmentIconColor = colorFromHash(worktreeHash)
  const instanceName = `${worktreeName}-${instanceHash}`
  // Per-instance URL scheme, mirroring the per-instance bundle identifier:
  // every dev worktree registering plain codevisor-dev:// would leave
  // LaunchServices routing deeplinks to an arbitrary one of them. The Swift
  // deeplink parsers accept the whole codevisor-dev-* family.
  const urlScheme = `codevisor-dev-${instanceHash}`
  const appName = `Codevisor (${worktreeName})`
  const macOSBundleIdentifier = `com.851labs.Codevisor.Development.${instanceHash}`
  const iOSBundleIdentifier = iosDevelopmentBundleIdentifier(repoRoot)
  const layout = developmentLayout(repoRoot)
  const derivedDataPath = layout.build.macos.derivedData
  const appBundle = join(derivedDataPath, "Build", "Products", "Debug", `${appName}.app`)
  const appExecutable = join(appBundle, "Contents", "MacOS", appName)
  const simulatorName = environment.CODEVISOR_IOS_SIMULATOR ?? "iPhone 17 Pro"

  const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
  const requestedPort = parsePort(
    environment.CODEVISOR_DEV_PORT ?? environment.HERDMAN_DEV_PORT,
    "CODEVISOR_DEV_PORT"
  )
  const port = requestedPort ?? (await findAvailablePort(preferredPort, 51_000, 10_000))

  const preferredWwwPort = 61_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 4_000)
  const requestedWwwPort = parsePort(environment.CODEVISOR_DEV_WWW_PORT, "CODEVISOR_DEV_WWW_PORT")
  const wwwPort = requestedWwwPort ?? (await findAvailablePort(preferredWwwPort, 61_000, 4_000))

  // Two standalone dev servers on this machine, each isolated from the local
  // instance and from each other, named for the transport they exercise:
  // - Dev Direct: added by token/deeplink; NEVER joins the dev cloud.
  // - Dev Cloud: signs into the dev cloud; reached through the relay only.
  const directRemotePort = await findAvailablePort(port + 1, 51_000, 10_000)
  const cloudRemotePort = await findAvailablePort(directRemotePort + 1, 51_000, 10_000)

  return {
    appBundle,
    appExecutable,
    appName,
    // The mac app's own server carries a name that says what it is in machine
    // lists (the cloud hub, other devices' fleets).
    appServerName: `Mac App (${worktreeName})`,
    cloudRemoteName: `Dev Cloud (${worktreeName})`,
    cloudRemotePort,
    // The local dev instance and a standalone "remote" server each get their
    // own production-shaped roots under tmp/: codevisor mirrors ~/codevisor
    // and .codevisor mirrors ~/.codevisor. The fake remote repeats that layout.
    dataDirectory: layout.local.data,
    derivedDataPath,
    developmentIconColor,
    directRemoteName: `Dev Direct (${worktreeName})`,
    directRemotePort,
    iOSBundleIdentifier,
    instanceHash,
    instanceName,
    layout,
    macOSBundleIdentifier,
    port,
    remoteDataDirectory: layout.remote.data,
    simulatorName,
    tmpRoot: layout.tmpRoot,
    urlScheme,
    worktreeName,
    worktreesDirectory: layout.local.worktrees,
    wwwPort
  }
}

/// One-time moves of earlier dev state into the production-shaped layout.
export async function migrateLegacyDevelopmentState(instance, repoRoot) {
  const { dataDirectory, instanceName, layout, remoteDataDirectory, tmpRoot } = instance
  // Earlier local app/server state lived in tmp/codevisor, the repo's
  // .codevisor, or Application Support. The old tmp/codevisor path is
  // recognized only when it contains a server DB; after this migration that
  // path belongs exclusively to dev worktrees.
  if (dataDirectory === layout.local.data && (await directoryIsEmpty(dataDirectory))) {
    for (const previous of [
      join(tmpRoot, "codevisor"),
      join(repoRoot, ".codevisor"),
      join(homedir(), "Library", "Application Support", "Codevisor Development", instanceName)
    ]) {
      const isLegacyTmpData = previous === join(tmpRoot, "codevisor")
      if (
        (await pathExists(previous)) &&
        (!isLegacyTmpData || (await pathExists(join(previous, "codevisor-server.sqlite"))))
      ) {
        console.log(`Moving dev state into ${dataDirectory}`)
        await rm(dataDirectory, { recursive: true, force: true })
        await mkdir(layout.local.root, { recursive: true })
        await cp(previous, dataDirectory, { recursive: true })
        await rm(previous, { recursive: true, force: true })
        break
      }
    }
  }

  // The old fake-remote root contained flat server state. Move it only when it
  // has no nested repos/worktrees whose Git metadata contains absolute paths.
  const legacyRemoteDataDirectory = join(tmpRoot, "codevisor-remote")
  if (
    (await pathExists(join(legacyRemoteDataDirectory, "codevisor-server.sqlite"))) &&
    (await directoryIsEmpty(remoteDataDirectory)) &&
    !(await containsAnyPath(legacyRemoteDataDirectory, ["repos", "plugins", "worktrees"]))
  ) {
    console.log(`Moving dev remote state into ${remoteDataDirectory}`)
    await rm(remoteDataDirectory, { recursive: true, force: true })
    await mkdir(layout.remote.root, { recursive: true })
    await cp(legacyRemoteDataDirectory, remoteDataDirectory, { recursive: true })
    await rm(legacyRemoteDataDirectory, { recursive: true, force: true })
  }
}
