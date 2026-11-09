import { spawn } from "node:child_process"
import { createWriteStream, existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import { pipeline } from "node:stream/promises"

import type { UpdateApplyState, UpdateInfo } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { installRuntime, planRestart, resolveInstallRoot } from "@codevisor/updater"
import {
  channelFromSyncedValue,
  explainDiskFull,
  serverUpdateCache,
  DEFAULT_GITHUB_REPOSITORY,
  DEFAULT_LEGACY_RELEASE_BASE_URL,
  DEFAULT_SPARKLE_FEED_URL,
  fetchLatestServerRelease,
  fetchLatestSparkleRelease,
  isNewerRelease,
  parseSha256,
  readAppUpdateApplyState,
  readMachineUpdateChannel,
  readMachineUpdateFeedURL,
  sha256File
} from "@codevisor/updater"
import type { ServerRelease, ServerUpdateChannel, ServerUpdatePrune } from "@codevisor/updater"
import { Effect } from "effect"

import { failedApply, handOffToHostApp, latestApplyState } from "./serve-app-handoff.js"
import { SERVER_PROCESS_TITLE, SERVER_UPDATE_CHECK_TTL_MS } from "./serve-boot.js"
import type { CodevisorServerUpdater } from "./server.js"

const APP_UPDATE_HANDOFF_EXIT_CODE = 85

const startDetachedHandoff = (
  command: string,
  args: ReadonlyArray<string>,
  detached: boolean
): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, [...args], { detached, stdio: "ignore" })
    child.unref()
    child.on("error", (cause) =>
      reject(new Error(`Could not hand the update off to ${command}: ${cause.message}`))
    )
    child.once("spawn", () => resolve())
  })

const appHosted = (): boolean =>
  process.env.CODEVISOR_APP_HOSTED === "1" || process.env.HERDMAN_APP_HOSTED === "1"

const GITHUB_RELEASE_REPOSITORY =
  process.env.CODEVISOR_GITHUB_REPOSITORY ?? DEFAULT_GITHUB_REPOSITORY

const LEGACY_RELEASE_BASE_URL =
  process.env.CODEVISOR_LEGACY_RELEASE_BASE_URL ??
  process.env.CODEVISOR_RELEASE_BASE_URL ??
  process.env.HERDMAN_RELEASE_BASE_URL ??
  DEFAULT_LEGACY_RELEASE_BASE_URL

const releasePlatform = () => {
  if (process.platform === "darwin") return "darwin"
  if (process.platform === "linux") return "linux"
  return undefined
}

const releaseArch = () => {
  if (process.arch === "arm64") return "arm64"
  if (process.arch === "x64") return "x64"
  return undefined
}

const releaseTarget = (): string | undefined => {
  const platform = releasePlatform()
  const arch = releaseArch()
  return platform !== undefined && arch !== undefined ? `${platform}-${arch}` : undefined
}

export const makeSelfUpdater = (options: {
  readonly currentVersion: string
  readonly currentBuildNumber?: number | undefined
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly serveArgs: ReadonlyArray<string>
  readonly fetch?: typeof globalThis.fetch | undefined
}): CodevisorServerUpdater => {
  const cached = new Map<
    ServerUpdateChannel,
    {
      readonly at: number
      readonly info: UpdateInfo
      readonly release: ServerRelease | undefined
    }
  >()

  const download = options.fetch ?? globalThis.fetch
  const updates = serverUpdateCache({
    dataDir: options.dataDir,
    runningEntrypoint: process.argv[1]
  })
  void reportPrune(updates.prune([]))

  const syncedChannel = async (): Promise<ServerUpdateChannel | undefined> => {
    const entries = await Effect.runPromise(options.db.getSyncEntries("settings")).catch(
      () => undefined
    )
    const entry = entries?.find((item) => item.key === "updateChannel" && item.deleted !== true)
    return channelFromSyncedValue(entry?.value)
  }
  const resolveChannel = async (requested: ServerUpdateChannel): Promise<ServerUpdateChannel> => {
    let fileChannel: ServerUpdateChannel | undefined
    if (appHosted()) fileChannel = readMachineUpdateChannel(options.dataDir)
    return fileChannel ?? (await syncedChannel()) ?? requested
  }

  let lastFailure: UpdateApplyState | undefined

  const withApplyState = (info: UpdateInfo): UpdateInfo => {
    const reported = appHosted() ? readAppUpdateApplyState(options.dataDir) : undefined
    const lastApply = latestApplyState(reported, lastFailure)
    return lastApply === undefined ? info : { ...info, lastApply }
  }

  const fetchManifestRelease = (
    channel: ServerUpdateChannel,
    target: string
  ): Promise<ServerRelease | undefined> =>
    fetchLatestServerRelease({
      channel,
      repository: GITHUB_RELEASE_REPOSITORY,
      legacyBaseURL: LEGACY_RELEASE_BASE_URL,
      target,
      fetch: options.fetch
    })

  const resolveRelease = async (
    channel: ServerUpdateChannel
  ): Promise<ServerRelease | undefined> => {
    const target = releaseTarget()
    if (target === undefined) return undefined
    if (appHosted()) {
      const release = await fetchLatestSparkleRelease({
        feedURL: readMachineUpdateFeedURL(options.dataDir) ?? DEFAULT_SPARKLE_FEED_URL,
        channel,
        fetch: options.fetch
      }).catch(() => undefined)
      if (release !== undefined) return release
    }
    return fetchManifestRelease(channel, target)
  }

  const check = async (checkOptions?: {
    readonly force?: boolean
    readonly channel?: ServerUpdateChannel
  }): Promise<UpdateInfo> => {
    const channel = await resolveChannel(checkOptions?.channel ?? "stable")
    const hit = cached.get(channel)
    if (
      checkOptions?.force !== true &&
      hit !== undefined &&
      Date.now() - hit.at < SERVER_UPDATE_CHECK_TTL_MS
    ) {
      return withApplyState(hit.info)
    }
    let release: ServerRelease | undefined
    try {
      release = await resolveRelease(channel)
    } catch {}
    const info: UpdateInfo = {
      currentVersion: options.currentVersion,
      latestVersion: release?.version ?? options.currentVersion,
      updateAvailable:
        release !== undefined &&
        isNewerRelease(release, {
          version: options.currentVersion,
          buildNumber: options.currentBuildNumber
        }),
      channel,
      checkedAt: new Date().toISOString(),
      migrationState: "idle",
      ...(options.currentBuildNumber === undefined
        ? {}
        : { currentBuildNumber: options.currentBuildNumber }),
      ...(release?.buildNumber === undefined ? {} : { latestBuildNumber: release.buildNumber })
    }
    await Effect.runPromise(options.db.setUpdateInfo(info)).catch(() => undefined)
    cached.set(channel, { at: Date.now(), info, release })
    return withApplyState(info)
  }

  let applying: Promise<void> | undefined

  const apply = (applyOptions?: { readonly channel?: ServerUpdateChannel }): Promise<void> => {
    applying ??= applyOnce(applyOptions)
    return applying
  }

  const applyOnce = async (applyOptions?: {
    readonly channel?: ServerUpdateChannel
  }): Promise<void> => {
    lastFailure = undefined
    try {
      const restarting = await applyRelease(applyOptions)
      if (!restarting) applying = undefined
    } catch (cause) {
      applying = undefined
      lastFailure = failedApply(cause)
      throw cause
    }
  }

  const applyRelease = async (applyOptions?: {
    readonly channel?: ServerUpdateChannel
  }): Promise<boolean> => {
    const channel = await resolveChannel(applyOptions?.channel ?? "stable")
    const info = await check({ channel })
    if (!info.updateAvailable) return false

    if (appHosted()) {
      await handOffToApp(info.latestVersion)
      return false
    }

    const target = requireReleaseTarget()
    const release = await releaseFor(channel, target, info.latestVersion)
    const installRoot = resolveInstallRoot(process.argv[1])
    const runtimeRoot = await stageRelease(release, target, installRoot)
    await restartInto(release.version, runtimeRoot, installRoot)
    return true
  }

  const handOffToApp = async (version: string): Promise<void> => {
    console.log("Handing update off to the host macOS app")
    const requestPath = process.env.CODEVISOR_APP_UPDATE_REQUEST_PATH
    if (requestPath !== undefined && requestPath.length > 0) {
      await handOffToHostApp({ requestPath, dataDir: options.dataDir, version })
      return
    }
    setTimeout(() => process.exit(APP_UPDATE_HANDOFF_EXIT_CODE), 300)
  }

  const releaseFor = async (
    channel: ServerUpdateChannel,
    target: string,
    version: string
  ): Promise<ServerRelease> => {
    let release = cached.get(channel)?.release
    if (release === undefined || release.version !== version) {
      release = await fetchManifestRelease(channel, target)
    }
    if (release === undefined || release.version !== version) {
      throw new Error(`Release assets for Codevisor server ${version} are unavailable`)
    }
    return release
  }

  const stageRelease = async (
    release: ServerRelease,
    target: string,
    installRoot: string | undefined
  ): Promise<string> => {
    await reportPrune(updates.prune([release.version]))
    try {
      return await installRelease(release, target, installRoot)
    } catch (cause) {
      await reportPrune(updates.discard(release.version))
      throw explainDiskFull(cause, updates.directory)
    }
  }

  const installRelease = async (
    release: ServerRelease,
    target: string,
    installRoot: string | undefined
  ): Promise<string> => {
    const updateDir = updates.versionDirectory(release.version)
    const archivePath = join(updateDir, `codevisor-server-${target}.tar.gz`)
    mkdirSync(updateDir, { recursive: true })
    await downloadArchive(release, archivePath)
    await verifyChecksum(release, archivePath)
    if (installRoot === undefined) return extractRuntime(archivePath, join(updateDir, "runtime"))

    await installRuntime({
      installRoot,
      extract: (destination) => extractArchive(archivePath, destination)
    })
    await reportPrune(updates.discard(release.version))
    return installRoot
  }

  const downloadArchive = async (release: ServerRelease, archivePath: string): Promise<void> => {
    const url = release.archiveURL
    console.log(`Downloading Codevisor server ${release.version} from ${url}`)
    const response = await download(url, { signal: AbortSignal.timeout(300_000) })
    if (!response.ok || response.body === null) {
      throw new Error(`Failed to download ${url}: HTTP ${response.status}`)
    }
    await ensureRoomFor(response, response.body)
    await pipeline(response.body, createWriteStream(archivePath))
  }

  const ensureRoomFor = async (response: Response, body: ReadableStream): Promise<void> => {
    try {
      await updates.ensureRoomFor(contentLength(response))
    } catch (cause) {
      await body.cancel().catch(() => undefined)
      throw cause
    }
  }

  const verifyChecksum = async (release: ServerRelease, archivePath: string): Promise<void> => {
    if (release.checksumURL === undefined) return

    const checksumResponse = await download(release.checksumURL, {
      signal: AbortSignal.timeout(30_000)
    })
    if (!checksumResponse.ok) {
      throw new Error(`Failed to download ${release.checksumURL}: HTTP ${checksumResponse.status}`)
    }
    const expected = parseSha256(await checksumResponse.text())
    if (expected === undefined) {
      throw new Error(`Invalid SHA-256 sidecar at ${release.checksumURL}`)
    }
    const actual = await sha256File(archivePath)
    if (actual !== expected) {
      throw new Error(
        `Checksum mismatch for ${release.archiveURL}: expected ${expected}, got ${actual}`
      )
    }
  }

  const restartInto = async (
    version: string,
    runtimeRoot: string,
    installRoot: string | undefined
  ): Promise<void> => {
    console.log(`Restarting into Codevisor server ${version}`)
    const plan = planRestart(process.env, process.geteuid?.() ?? 0)
    if (plan.kind === "systemd" && installRoot !== undefined) {
      const managerArgs = plan.userManager ? ["--user"] : []
      await startDetachedHandoff(
        "systemctl",
        [...managerArgs, "restart", "--no-block", plan.unit],
        false
      )
      setTimeout(() => process.exit(0), 10_000).unref()
      return
    }

    await startDetachedHandoff(
      "/bin/bash",
      [
        "-c",
        `sleep 1; exec -a ${SERVER_PROCESS_TITLE} "$@"`,
        "bash",
        join(runtimeRoot, "bin", "node"),
        join(runtimeRoot, "main.js"),
        "serve",
        ...options.serveArgs
      ],
      true
    )
    setTimeout(() => process.exit(0), 300)
  }

  return { check, apply }
}

const requireReleaseTarget = (): string => {
  const target = releaseTarget()
  if (target === undefined) {
    throw new Error(`Self-update is not supported on ${process.platform}/${process.arch}`)
  }
  return target
}

const extractRuntime = async (archivePath: string, runtimeDir: string): Promise<string> => {
  mkdirSync(runtimeDir, { recursive: true })
  await extractArchive(archivePath, runtimeDir)
  if (!existsSync(join(runtimeDir, "main.js")) || !existsSync(join(runtimeDir, "bin", "node"))) {
    throw new Error(`Downloaded runtime at ${runtimeDir} is incomplete`)
  }
  return runtimeDir
}

const extractArchive = (archivePath: string, destination: string): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    const untar = spawn("tar", ["-xzf", archivePath, "-C", destination], { stdio: "ignore" })
    untar.once("error", reject)
    untar.once("exit", (code) => {
      if (code === 0) resolve()
      else reject(new Error(`tar exited with ${code}`))
    })
  })

const contentLength = (response: Response): number | undefined => {
  const bytes = Number(response.headers.get("content-length"))
  return Number.isFinite(bytes) && bytes > 0 ? bytes : undefined
}

const reportPrune = async (pruning: Promise<ServerUpdatePrune>): Promise<void> => {
  try {
    const prune = await pruning
    if (prune.removed.length > 0) {
      console.log(`Removed old Codevisor server updates: ${prune.removed.join(", ")}`)
    }
    for (const failure of prune.failures) {
      console.error(`Could not remove the server update ${failure.entry}: ${failure.message}`)
    }
  } catch (cause) {
    console.error(`Could not clean up Codevisor server updates: ${String(cause)}`)
  }
}
