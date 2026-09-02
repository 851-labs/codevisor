import type { UpdateInfo } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { spawn } from "node:child_process"
import { createWriteStream, existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs"
import { installRuntime, planRestart, resolveInstallRoot } from "@codevisor/updater"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { dirname, join } from "node:path"
import type { CodevisorServerUpdater } from "./server.js"
import {
  channelFromSyncedValue,
  DEFAULT_GITHUB_REPOSITORY,
  DEFAULT_LEGACY_RELEASE_BASE_URL,
  fetchLatestServerRelease,
  isNewerRelease,
  parseSha256,
  readAppUpdateApplyState,
  readMachineUpdateChannel,
  sha256File
} from "@codevisor/updater"
import type { ServerRelease, ServerUpdateChannel } from "@codevisor/updater"
import { SERVER_PROCESS_TITLE, SERVER_UPDATE_CHECK_TTL_MS } from "./serve-boot.js"

/// Self-updater for standalone server installs and the app-hosted handoff.

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

/// Whether a macOS app hosts this server as a child inside its .app bundle.
const appHosted = (): boolean =>
  process.env.CODEVISOR_APP_HOSTED === "1" || process.env.HERDMAN_APP_HOSTED === "1"

const GITHUB_RELEASE_REPOSITORY =
  process.env.CODEVISOR_GITHUB_REPOSITORY ?? DEFAULT_GITHUB_REPOSITORY

/// Compatibility fallback frozen at the first GitHub-aware release. Preserve
/// the old override names for managed installations that already set them.
const LEGACY_RELEASE_BASE_URL =
  process.env.CODEVISOR_LEGACY_RELEASE_BASE_URL ??
  process.env.CODEVISOR_RELEASE_BASE_URL ??
  process.env.HERDMAN_RELEASE_BASE_URL ??
  DEFAULT_LEGACY_RELEASE_BASE_URL

/// "darwin-arm64", "linux-x64", … matching the published server archives.
const releaseTarget = (): string | undefined => {
  const platform =
    process.platform === "darwin" ? "darwin" : process.platform === "linux" ? "linux" : undefined
  const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "x64" : undefined
  return platform !== undefined && arch !== undefined ? `${platform}-${arch}` : undefined
}

/// Self-updater for standalone server installs: checks GitHub's latest stable
/// release and on apply downloads the matching server archive,
/// unpacks it next to the database, hands off to the new runtime, and exits.
export const makeSelfUpdater = (options: {
  readonly currentVersion: string
  readonly currentBuildNumber?: number | undefined
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly serveArgs: ReadonlyArray<string>
}): CodevisorServerUpdater => {
  // Per-channel: an alpha check must never satisfy a stable one (or vice
  // versa) — they read different manifests.
  const cached = new Map<
    ServerUpdateChannel,
    {
      readonly at: number
      readonly info: UpdateInfo
      readonly release: ServerRelease | undefined
    }
  >()

  // On an app-hosted Mac the machine's own channel preference — written by
  // the host app next to the database — is authoritative: Sparkle installs
  // from that preference, so letting a remote client's requested channel
  // decide the check would let check and install disagree and the update
  // never converge. Standalone servers follow the config plane's synced
  // channel the same way; the requested channel is only the fallback.
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

  // Attached fresh on every check, never cached: the host app's unattended
  // Sparkle session writes this while installing (or after failing), and a
  // remote client polling for the outcome needs the live state.
  const withApplyState = (info: UpdateInfo): UpdateInfo => {
    if (!appHosted()) return info
    const lastApply = readAppUpdateApplyState(options.dataDir)
    return lastApply === undefined ? info : { ...info, lastApply }
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
      const target = releaseTarget()
      if (target !== undefined) {
        release = await fetchLatestServerRelease({
          channel,
          repository: GITHUB_RELEASE_REPOSITORY,
          legacyBaseURL: LEGACY_RELEASE_BASE_URL,
          target
        })
      }
    } catch {
      // Offline or unreachable: report the last known state.
    }
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
      // Build numbers are the cross-feed authority clients compare to see
      // whether an update landed: alpha manifests carry the full prerelease
      // tag while installed runtimes report their base marketing version,
      // so version strings alone cannot confirm convergence.
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
    // A macOS app hosts this server as a child inside its .app bundle: a
    // standalone runtime swap here lives under Application Support and would be
    // discarded on the app's next launch (which re-runs the bundled runtime).
    // Hand the update back to the app — it replaces the whole bundle and
    // relaunches, bringing a fresh bundled server — by exiting with the agreed
    // status the app is watching for.
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
      release = await fetchLatestServerRelease({
        channel,
        repository: GITHUB_RELEASE_REPOSITORY,
        legacyBaseURL: LEGACY_RELEASE_BASE_URL,
        target
      })
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

    // Install over the running root so systemd's ExecStart and the launcher
    // symlinks boot the new version. Without this the staged runtime never
    // becomes the default and every later restart resurrects the old build.
    const installRoot = resolveInstallRoot(process.argv[1])
    if (installRoot !== undefined) {
      await installRuntime({ installRoot, extract: extractArchive })
    }

    console.log(`Restarting into Codevisor server ${info.latestVersion}`)
    const plan = planRestart(process.env, process.geteuid?.() ?? 0)
    if (plan.kind === "systemd" && installRoot !== undefined) {
      // Ask PID 1 to restart the unit. A detached handoff child would die
      // with this unit's cgroup, and a clean exit is final under
      // Restart=on-failure — but a restart job enqueued with --no-block
      // survives this process: its stop half takes this server down and its
      // start half boots the swapped install root.
      const managerArgs = plan.userManager ? ["--user"] : []
      spawn("systemctl", [...managerArgs, "restart", "--no-block", plan.unit], {
        stdio: "ignore"
      }).unref()
      // Failsafe: if the restart job never arrives, exit anyway — the
      // install root is already swapped, so any later start (manual or
      // scheduled) boots the new version.
      setTimeout(() => process.exit(0), 10_000).unref()
      return
    }

    // Hand off: the replacement waits a beat for this process to release the
    // port, then execs the new runtime with the same serve arguments. Runs
    // from the swapped install root when there is one so the process and the
    // install agree on the version; dev-style runs use the staged runtime.
    const handoffRoot = installRoot ?? runtimeDir
    const handoff = spawn(
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
      { detached: true, stdio: "ignore" }
    )
    handoff.unref()
    setTimeout(() => process.exit(0), 300)
  }

  return { check, apply }
}
