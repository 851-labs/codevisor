#!/usr/bin/env node
import {
  makeAgentRuntime,
  resolveShellEnv,
  type BackgroundTerminalIntegration
} from "@herdman/agent-runtime"
import type { DataUpgradeProgress, UpdateInfo } from "@herdman/api"
import { makeDatabase, type HerdManDatabaseService } from "@herdman/db"
import { makeTerminalManager, type TerminalManagerService } from "@herdman/terminal"
import { Effect } from "effect"
import { spawn } from "node:child_process"
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { startBackgroundTerminalHost, wrapBackgroundCommand } from "./background-terminal-host.js"
import {
  defaultDatabasePath,
  defaultServerConfig,
  startHerdManServer,
  type HerdManServerUpdater
} from "./server.js"

const SERVER_PROCESS_TITLE = "herdman-server"

const writeDataUpgradeStatus = (path: string, progress: DataUpgradeProgress): void => {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(temporary, `${JSON.stringify(progress)}\n`, "utf8")
  renameSync(temporary, path)
}

/// Exit status used to hand an update back to a host macOS app: a server that
/// lives inside the .app bundle can't replace that bundle, so instead of
/// swapping a standalone runtime (which the app's next launch would discard) it
/// exits with this status and the app performs the full app update + relaunch.
/// Must match `LocalHerdManServer.updateHandoffExitStatus`.
const APP_UPDATE_HANDOFF_EXIT_CODE = 85

process.title = SERVER_PROCESS_TITLE

const parseArgs = (args: ReadonlyArray<string>): Record<string, string> => {
  const parsed: Record<string, string> = {}
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg?.startsWith("--") === true) {
      parsed[arg.slice(2)] = args[index + 1] ?? ""
      index += 1
    }
  }
  return parsed
}

const bundledVersion = (): string | undefined => {
  if (process.env.HERDMAN_VERSION !== undefined && process.env.HERDMAN_VERSION.length > 0) {
    return process.env.HERDMAN_VERSION
  }

  const versionPath = join(dirname(fileURLToPath(import.meta.url)), "VERSION")
  if (!existsSync(versionPath)) {
    return undefined
  }

  const version = readFileSync(versionPath, "utf8").trim()
  return version.length > 0 ? version : undefined
}

/// The public artifact bucket that distributes server releases (the same one
/// the Homebrew formula installs from). The source repository is private, so
/// update checks go through this bucket, not the GitHub API.
const RELEASE_BASE_URL =
  process.env.HERDMAN_RELEASE_BASE_URL ??
  "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/herdman"

/// "darwin-arm64", "linux-x64", … matching the published server archives.
const releaseTarget = (): string | undefined => {
  const platform =
    process.platform === "darwin" ? "darwin" : process.platform === "linux" ? "linux" : undefined
  const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "x64" : undefined
  return platform !== undefined && arch !== undefined ? `${platform}-${arch}` : undefined
}

const isNewerVersion = (candidate: string, current: string): boolean => {
  const parse = (version: string): ReadonlyArray<number> =>
    (version.replace(/^v/, "").split("-")[0] ?? "").split(".").map((part) => Number(part) || 0)
  const left = parse(candidate)
  const right = parse(current)
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index] ?? 0
    const b = right[index] ?? 0
    if (a !== b) {
      return a > b
    }
  }
  return false
}

/// Self-updater for standalone server installs: checks the release manifest
/// on the artifact bucket, and on apply downloads the matching server archive,
/// unpacks it next to the database, hands off to the new runtime, and exits.
const makeSelfUpdater = (options: {
  readonly currentVersion: string
  readonly db: HerdManDatabaseService
  readonly dataDir: string
  readonly serveArgs: ReadonlyArray<string>
}): HerdManServerUpdater => {
  let cached: { readonly at: number; readonly info: UpdateInfo } | undefined

  const check = async (): Promise<UpdateInfo> => {
    if (cached !== undefined && Date.now() - cached.at < 60_000) {
      return cached.info
    }
    let latestVersion = options.currentVersion
    try {
      const response = await fetch(`${RELEASE_BASE_URL}/latest.json`, {
        headers: { "cache-control": "no-cache" },
        signal: AbortSignal.timeout(10_000)
      })
      if (response.ok) {
        const manifest = (await response.json()) as { readonly version?: string }
        const version = (manifest.version ?? "").replace(/^v/, "")
        if (version.length > 0) {
          latestVersion = version
        }
      }
    } catch {
      // Offline or unreachable: report the last known state.
    }
    const info: UpdateInfo = {
      currentVersion: options.currentVersion,
      latestVersion,
      updateAvailable: isNewerVersion(latestVersion, options.currentVersion),
      channel: "stable",
      checkedAt: new Date().toISOString(),
      migrationState: "idle"
    }
    await Effect.runPromise(options.db.setUpdateInfo(info)).catch(() => undefined)
    cached = { at: Date.now(), info }
    return info
  }

  const apply = async (): Promise<void> => {
    const info = await check()
    if (!info.updateAvailable) {
      return
    }
    // A macOS app hosts this server as a child inside its .app bundle: a
    // standalone runtime swap here lives under Application Support and would be
    // discarded on the app's next launch (which re-runs the bundled runtime).
    // Hand the update back to the app — it replaces the whole bundle and
    // relaunches, bringing a fresh bundled server — by exiting with the agreed
    // status the app is watching for.
    if (process.env.HERDMAN_APP_HOSTED === "1") {
      console.log("Handing update off to the host macOS app")
      setTimeout(() => process.exit(APP_UPDATE_HANDOFF_EXIT_CODE), 300)
      return
    }
    const target = releaseTarget()
    if (target === undefined) {
      throw new Error(`Self-update is not supported on ${process.platform}/${process.arch}`)
    }

    const updateDir = join(options.dataDir, "server-updates", info.latestVersion)
    const archivePath = join(updateDir, `herdman-server-${target}.tar.gz`)
    const runtimeDir = join(updateDir, "runtime")
    mkdirSync(runtimeDir, { recursive: true })

    const url = `${RELEASE_BASE_URL}/v${info.latestVersion}/herdman-server-${target}.tar.gz`
    console.log(`Downloading HerdMan server ${info.latestVersion} from ${url}`)
    const response = await fetch(url, { signal: AbortSignal.timeout(300_000) })
    if (!response.ok || response.body === null) {
      throw new Error(`Failed to download ${url}: HTTP ${response.status}`)
    }
    await pipeline(
      Readable.fromWeb(response.body as import("node:stream/web").ReadableStream),
      createWriteStream(archivePath)
    )

    await new Promise<void>((resolve, reject) => {
      const untar = spawn("tar", ["-xzf", archivePath, "-C", runtimeDir], { stdio: "ignore" })
      untar.once("error", reject)
      untar.once("exit", (code) =>
        code === 0 ? resolve() : reject(new Error(`tar exited with ${code}`))
      )
    })

    const entrypoint = join(runtimeDir, "main.js")
    const nodeBinary = join(runtimeDir, "bin", "node")
    if (!existsSync(entrypoint) || !existsSync(nodeBinary)) {
      throw new Error(`Downloaded runtime at ${runtimeDir} is incomplete`)
    }

    // Hand off: the replacement waits a beat for this process to release the
    // port, then execs the new runtime with the same serve arguments.
    console.log(`Restarting into HerdMan server ${info.latestVersion}`)
    const handoff = spawn(
      "/bin/bash",
      [
        "-c",
        `sleep 1; exec -a ${SERVER_PROCESS_TITLE} "$@"`,
        "bash",
        nodeBinary,
        entrypoint,
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

/// Backs agent background processes with server-owned terminals: providers
/// register mirrors in-process through the registry, and out-of-process
/// wrappers (background Bash) attach over the unix-socket host. Best-effort —
/// a host failure degrades to the plain no-terminal behavior.
const backgroundTerminalIntegration = async (
  terminal: TerminalManagerService
): Promise<BackgroundTerminalIntegration | undefined> => {
  const registry: BackgroundTerminalIntegration["registry"] = {
    register: (key, controls) => {
      const handle = terminal.registerExternalTerminal(
        { sessionId: key, normalizeNewlines: true },
        {
          write: controls.write ?? (() => undefined),
          resize: controls.resize ?? (() => undefined),
          kill: controls.kill ?? (() => undefined)
        }
      )
      return { output: handle.output, exit: handle.exit, remove: handle.remove }
    }
  }
  try {
    const host = await startBackgroundTerminalHost({
      registry,
      // tmpdir keeps the path under the unix-socket length limit (the data
      // dir under Application Support routinely is not).
      socketPath: join(tmpdir(), `herdman-bg-${process.pid}.sock`)
    })
    const runtimeDir = dirname(fileURLToPath(import.meta.url))
    return {
      registry,
      wrapCommand: wrapBackgroundCommand({
        nodePath: process.execPath,
        socketPath: host.socketPath,
        wrapperPath: join(runtimeDir, "bg-wrap.js")
      })
    }
  } catch (cause) {
    console.error(
      `Background terminal host unavailable: ${cause instanceof Error ? cause.message : String(cause)}`
    )
    return { registry }
  }
}

const main = Effect.gen(function* () {
  const command = process.argv[2] ?? "serve"
  if (command !== "serve") {
    throw new Error(`Unsupported command: ${command}`)
  }

  const args = parseArgs(process.argv.slice(3))
  const host = args.host ?? "127.0.0.1"
  const port = Number(args.port ?? "49361")
  const serverId = args.serverId ?? "local"
  const authMode = args.auth ?? (host === "127.0.0.1" ? "none" : "token")
  const version = args.version ?? bundledVersion()
  if (authMode !== "none" && authMode !== "token") {
    throw new Error("--auth must be either none or token")
  }
  const kind = args.kind
  if (kind !== undefined && kind !== "local" && kind !== "remote") {
    throw new Error("--kind must be either local or remote")
  }
  // Browser origins allowed to call the API cross-origin (comma-separated),
  // e.g. the Tauri webview's tauri://localhost. Never pass a wildcard here.
  const corsOrigins = (args["cors-origins"] ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin.length > 0)
  const databasePath = args.db ?? defaultDatabasePath()
  const upgradeStatusPath =
    args["upgrade-status"] ?? join(dirname(databasePath), "data-upgrade.json")
  const db = yield* makeDatabase({
    filename: databasePath,
    serverId,
    onDataUpgradeProgress: (progress) => writeDataUpgradeStatus(upgradeStatusPath, progress)
  }).pipe(
    Effect.tapError((cause) =>
      Effect.sync(() =>
        writeDataUpgradeStatus(upgradeStatusPath, {
          state: "failed",
          id: "database-startup",
          name: "Applying update",
          completed: 0,
          total: 0,
          error: cause.message
        })
      )
    )
  )
  // Self-update needs a known current version to compare against; dev runs
  // without a VERSION file simply don't offer it. The new runtime reads its
  // own bundled VERSION, so --version is not forwarded.
  const updater =
    version === undefined
      ? undefined
      : makeSelfUpdater({
          currentVersion: version,
          db,
          dataDir: dirname(databasePath),
          serveArgs: [
            "--host",
            host,
            "--port",
            String(port),
            "--db",
            databasePath,
            "--serverId",
            serverId,
            "--auth",
            authMode,
            ...(args.name === undefined ? [] : ["--name", args.name]),
            ...(args.kind === undefined ? [] : ["--kind", args.kind]),
            ...(corsOrigins.length === 0 ? [] : ["--cors-origins", corsOrigins.join(",")])
          ]
        })
  const terminal = makeTerminalManager()
  const backgroundTerminals = yield* Effect.promise(() => backgroundTerminalIntegration(terminal))
  const agents = makeAgentRuntime({
    ...(backgroundTerminals === undefined ? {} : { backgroundTerminals }),
    resolveEnv: () => resolveShellEnv()
  })
  // Self-heal PATH at boot, fire-and-forget: CLI-/brew-launched servers
  // inherit whatever PATH the parent had, and a slow login-shell probe must
  // not delay the health endpoint the launching app is waiting on.
  void Effect.runPromise(agents.refreshEnvironment).catch(() => undefined)
  const server = yield* startHerdManServer(
    {
      agents,
      db,
      terminal
    },
    defaultServerConfig({
      host,
      id: serverId,
      // The app launches its own server bound to 0.0.0.0 so remote clients
      // can connect; --kind lets it stay "local" despite the network bind.
      kind: kind ?? (host === "127.0.0.1" ? "local" : "remote"),
      name: args.name ?? (host === "127.0.0.1" ? "Local HerdMan" : serverId),
      port,
      ...(version === undefined ? {} : { version }),
      ...(corsOrigins.length === 0 ? {} : { corsOrigins }),
      auth: {
        // Same-machine clients (the app that launched this server, the
        // terminal proxy) are trusted without a token; only connections
        // arriving over the network must present one.
        allowLocalhostWithoutAuth: authMode === "token",
        requireBearerToken: authMode === "token"
      },
      onShutdownRequested: () => {
        console.log("HerdMan server shutting down (requested by client)")
        // Let the 202 response flush before the process exits.
        setTimeout(() => process.exit(0), 250)
      },
      updater
    })
  )
  console.log(`HerdMan server listening at ${server.url}`)
})

Effect.runPromise(main).catch((cause: unknown) => {
  console.error(cause instanceof Error ? cause.message : String(cause))
  process.exitCode = 1
})
