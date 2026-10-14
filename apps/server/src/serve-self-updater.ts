import { spawn } from "node:child_process"
import { createWriteStream, existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"

import type { UpdateInfo } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { installRuntime, planRestart, resolveInstallRoot } from "@codevisor/updater"
import {
  channelFromSyncedValue,
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
import type { ServerRelease, ServerUpdateChannel } from "@codevisor/updater"
import { Effect } from "effect"

import { SERVER_PROCESS_TITLE, SERVER_UPDATE_CHECK_TTL_MS } from "./serve-boot.js"
import type { CodevisorServerUpdater } from "./server.js"

const APP_UPDATE_HANDOFF_EXIT_CODE = 85

const writeAppUpdateRequest = (path: string, version: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(
    temporary,
    `${JSON.stringify({
      version,
      requestedAt: new Date().toISOString(),
      pid: process.pid
    })}\n`,
    { encoding: "utf8", mode: 0o600 }
  )
  renameSync(temporary, path)
}

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

const releaseTarget = (): string | undefined => {
  const platform =
    process.platform === "darwin" ? "darwin" : process.platform === "linux" ? "linux" : undefined
  const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "x64" : undefined
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

  const syncedChannel = async (): Promise<ServerUpdateChannel | undefined> => {
    const entries = await Effect.runPromise(options.db.getSyncEntries("settings")).catch(
      () => undefined
    )
    const entry = entries?.find((item) => item.key === "updateChannel" && item.deleted !== true)
    return channelFromSyncedValue(entry?.value)
  }
  const resolveChannel = async (requested: ServerUpdateChannel): Promise<ServerUpdateChannel> => {
    const fileChannel = appHosted() ? readMachineUpdateChannel(options.dataDir) : undefined
    return fileChannel ?? (await syncedChannel()) ?? requested
  }

  const withApplyState = (info: UpdateInfo): UpdateInfo => {
    if (!appHosted()) return info
    const lastApply = readAppUpdateApplyState(options.dataDir)
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

  const apply = async (applyOptions?: {
    readonly channel?: ServerUpdateChannel
  }): Promise<void> => {
    const channel = await resolveChannel(applyOptions?.channel ?? "stable")
    const info = await check({ channel })
    if (!info.updateAvailable) {
      return
    }
    if (appHosted()) {
      console.log("Handing update off to the host macOS app")
      const requestPath = process.env.CODEVISOR_APP_UPDATE_REQUEST_PATH
      if (requestPath !== undefined && requestPath.length > 0) {
        writeAppUpdateRequest(requestPath, info.latestVersion)
        return
      }
      setTimeout(() => process.exit(APP_UPDATE_HANDOFF_EXIT_CODE), 300)
      return
    }
    const target = releaseTarget()
    if (target === undefined) {
      throw new Error(`Self-update is not supported on ${process.platform}/${process.arch}`)
    }

    const updateDir = join(options.dataDir, "server-updates", info.latestVersion)
    const archivePath = join(updateDir, `codevisor-server-${target}.tar.gz`)
    const runtimeDir = join(updateDir, "runtime")
    mkdirSync(runtimeDir, { recursive: true })

    let release = cached.get(channel)?.release
    if (release === undefined || release.version !== info.latestVersion) {
      release = await fetchManifestRelease(channel, target)
    }
    if (release === undefined || release.version !== info.latestVersion) {
      throw new Error(`Release assets for Codevisor server ${info.latestVersion} are unavailable`)
    }

    const url = release.archiveURL
    console.log(`Downloading Codevisor server ${info.latestVersion} from ${url}`)
    const response = await fetch(url, { signal: AbortSignal.timeout(300_000) })
    if (!response.ok || response.body === null) {
      throw new Error(`Failed to download ${url}: HTTP ${response.status}`)
    }
    await pipeline(
      Readable.fromWeb(response.body as import("node:stream/web").ReadableStream),
      createWriteStream(archivePath)
    )

    if (release.checksumURL !== undefined) {
      const checksumResponse = await fetch(release.checksumURL, {
        signal: AbortSignal.timeout(30_000)
      })
      if (!checksumResponse.ok) {
        throw new Error(
          `Failed to download ${release.checksumURL}: HTTP ${checksumResponse.status}`
        )
      }
      const expected = parseSha256(await checksumResponse.text())
      if (expected === undefined) {
        throw new Error(`Invalid SHA-256 sidecar at ${release.checksumURL}`)
      }
      const actual = await sha256File(archivePath)
      if (actual !== expected) {
        throw new Error(`Checksum mismatch for ${url}: expected ${expected}, got ${actual}`)
      }
    }

    const extractArchive = (destination: string): Promise<void> =>
      new Promise<void>((resolve, reject) => {
        const untar = spawn("tar", ["-xzf", archivePath, "-C", destination], { stdio: "ignore" })
        untar.once("error", reject)
        untar.once("exit", (code) =>
          code === 0 ? resolve() : reject(new Error(`tar exited with ${code}`))
        )
      })
    await extractArchive(runtimeDir)

    if (!existsSync(join(runtimeDir, "main.js")) || !existsSync(join(runtimeDir, "bin", "node"))) {
      throw new Error(`Downloaded runtime at ${runtimeDir} is incomplete`)
    }

    const installRoot = resolveInstallRoot(process.argv[1])
    if (installRoot !== undefined) {
      await installRuntime({ installRoot, extract: extractArchive })
    }

    console.log(`Restarting into Codevisor server ${info.latestVersion}`)
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

    const handoffRoot = installRoot ?? runtimeDir
    await startDetachedHandoff(
      "/bin/bash",
      [
        "-c",
        `sleep 1; exec -a ${SERVER_PROCESS_TITLE} "$@"`,
        "bash",
        join(handoffRoot, "bin", "node"),
        join(handoffRoot, "main.js"),
        "serve",
        ...options.serveArgs
      ],
      true
    )
    setTimeout(() => process.exit(0), 300)
  }

  return { check, apply }
}
