import {
  makeAgentRuntime,
  resolveShellEnv,
  testAcpConnection,
  type BackgroundTerminalIntegration
} from "@codevisor/agent-runtime"
import type { DataUpgradeProgress, UpdateInfo } from "@codevisor/api"
import { makeDatabase, worktreesRoot, type CodevisorDatabaseService } from "@codevisor/db"
import { makeTerminalManager, type TerminalManagerService } from "@codevisor/terminal"
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
import { hostname, tmpdir } from "node:os"
import { installRuntime, planRestart, resolveInstallRoot } from "./self-update.js"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { startBackgroundTerminalHost, wrapBackgroundCommand } from "./background-terminal-host.js"
import { canonicalDatabasePaths, codevisorRoot, defaultDatabasePath } from "./data-dir.js"
import {
  customHarnessDefinition,
  loadCustomHarnesses,
  saveCustomHarnesses,
  type CustomHarnessStore
} from "./custom-harnesses.js"
import { isNewerVersion } from "./harness-update-sources.js"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"
import { defaultServerConfig, startCodevisorServer, type CodevisorServerUpdater } from "./server.js"
import { makeHarnessAuthManager } from "./harness-auth.js"
import { makeMcpManager } from "./mcp-manager.js"
import { makeNativeMcpManager } from "./native-mcp-manager.js"
import { makeSkillsManager } from "./skills-manager.js"
import { migrateLegacyLayout, migrateTmpDataDir } from "./legacy-layout.js"
import {
  DEFAULT_GITHUB_REPOSITORY,
  DEFAULT_LEGACY_RELEASE_BASE_URL,
  fetchLatestServerRelease,
  parseSha256,
  sha256File,
  type ServerRelease
} from "./release-source.js"

const SERVER_PROCESS_TITLE = "codevisor-server"
const SERVER_UPDATE_CHECK_TTL_MS = 6 * 60 * 60 * 1_000

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
/// Must match `LocalCodevisorServer.updateHandoffExitStatus`.
const APP_UPDATE_HANDOFF_EXIT_CODE = 85

export const parseArgs = (args: ReadonlyArray<string>): Record<string, string> => {
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

export const bundledVersion = (): string | undefined => {
  const override = process.env.CODEVISOR_VERSION ?? process.env.HERDMAN_VERSION
  if (override !== undefined && override.length > 0) {
    return override
  }

  const versionPath = join(dirname(fileURLToPath(import.meta.url)), "VERSION")
  if (!existsSync(versionPath)) {
    return undefined
  }

  const version = readFileSync(versionPath, "utf8").trim()
  return version.length > 0 ? version : undefined
}

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
const makeSelfUpdater = (options: {
  readonly currentVersion: string
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly serveArgs: ReadonlyArray<string>
}): CodevisorServerUpdater => {
  let cached:
    | {
        readonly at: number
        readonly info: UpdateInfo
        readonly release: ServerRelease | undefined
      }
    | undefined

  const check = async (): Promise<UpdateInfo> => {
    if (cached !== undefined && Date.now() - cached.at < SERVER_UPDATE_CHECK_TTL_MS) {
      return cached.info
    }
    let latestVersion = options.currentVersion
    let release: ServerRelease | undefined
    try {
      const target = releaseTarget()
      if (target !== undefined) {
        release = await fetchLatestServerRelease({
          repository: GITHUB_RELEASE_REPOSITORY,
          legacyBaseURL: LEGACY_RELEASE_BASE_URL,
          target
        })
        if (release !== undefined) {
          latestVersion = release.version
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
    cached = { at: Date.now(), info, release }
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
    if (process.env.CODEVISOR_APP_HOSTED === "1" || process.env.HERDMAN_APP_HOSTED === "1") {
      console.log("Handing update off to the host macOS app")
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

    let release = cached?.release
    if (release === undefined || release.version !== info.latestVersion) {
      release = await fetchLatestServerRelease({
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
      socketPath: join(tmpdir(), `codevisor-bg-${process.pid}.sock`)
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

/// Boots the Codevisor server from parsed `--flag value` arguments. Shared by
/// the `codevisor-server` daemon bin and the `codevisor serve` CLI subcommand.
export const runServe = (args: Record<string, string>): Promise<void> => {
  process.title = SERVER_PROCESS_TITLE

  const program = Effect.gen(function* () {
    const host = args.host ?? "127.0.0.1"
    const port = Number(args.port ?? "49361")
    const serverId = args.serverId ?? "local"
    const worktreeNameStyle =
      process.env.CODEVISOR_DEV_INSTANCE_ID !== undefined ||
      process.env.HERDMAN_DEV_INSTANCE_ID !== undefined
        ? "development"
        : "production"
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
    // The canonical ~/.codevisor/data directory does not exist on first start
    // (unlike the old tmpdir default, which always did).
    mkdirSync(dirname(databasePath), { recursive: true })
    const upgradeStatusPath =
      args["upgrade-status"] ?? join(dirname(databasePath), "data-upgrade.json")
    // Standalone installs used to default the database into the OS temp
    // directory; relocate that data the first time we start against a canonical
    // data-dir path (the systemd units pass --db explicitly, so an explicit flag
    // alone must not skip the migration). Other explicit --db paths — like the
    // macOS app's Application Support database — are the caller's responsibility.
    if (args.db === undefined || canonicalDatabasePaths().includes(databasePath)) {
      yield* Effect.tryPromise(() => migrateTmpDataDir({ databasePath }))
    }
    yield* Effect.tryPromise(() =>
      migrateLegacyLayout({
        databasePath,
        worktreesRoot: worktreesRoot(),
        onProgress: (progress) => writeDataUpgradeStatus(upgradeStatusPath, progress)
      })
    )
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
    // User-defined custom ACP harnesses (~/.codevisor/harnesses.json) merge
    // into the catalog before anything consumes it. Bad entries are skipped
    // with a warning — a hand-edited file must never block server boot.
    const customHarnesses = yield* Effect.promise(() => loadCustomHarnesses(codevisorRoot()))
    for (const warning of customHarnesses.warnings) {
      console.error(`Custom harnesses: ${warning}`)
    }
    const agents = makeAgentRuntime({
      ...(backgroundTerminals === undefined ? {} : { backgroundTerminals }),
      ...(customHarnesses.definitions.length === 0
        ? {}
        : { extraHarnesses: customHarnesses.definitions }),
      resolveEnv: () => resolveShellEnv()
    })
    const auth = makeHarnessAuthManager({
      dataDir: dirname(databasePath),
      db,
      agents,
      terminal,
      preferDeviceCode: (kind ?? (host === "127.0.0.1" ? "local" : "remote")) === "remote"
    })
    const skills = makeSkillsManager({ agents })
    const mcp = makeMcpManager({
      db,
      dataDir: dirname(databasePath),
      syncManagedSkills: skills.syncManaged
    })
    const nativeMcp = makeNativeMcpManager({
      agents,
      dataDir: dirname(databasePath),
      db,
      mcp
    })
    /// Custom-harness persistence + handshake probe for the /v1/harnesses/
    /// custom routes. The file stays the source of truth; replace() swaps the
    /// runtime catalog live so no restart is needed.
    const customHarnessStore: CustomHarnessStore = {
      list: async () => (await loadCustomHarnesses(codevisorRoot())).specs,
      replace: async (specs) => {
        await saveCustomHarnesses(codevisorRoot(), specs)
        agents.setExtraHarnesses(specs.map(customHarnessDefinition))
        await Effect.runPromise(agents.refreshEnvironment)
      },
      test: async (spec) =>
        testAcpConnection(
          {
            args: spec.args === undefined ? [] : [...spec.args],
            command: spec.command,
            ...(spec.env === undefined ? {} : { env: spec.env })
          },
          { env: await resolveShellEnv() }
        )
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents,
      db,
      resolveEnv: () => resolveShellEnv(),
      terminal
    })
    // Periodic harness update detection — jittered start, 6h cadence. The
    // stop handle is intentionally dropped: checks live for the process.
    lifecycle.startPeriodicChecks()
    // Interrupted updates become failures; still-armed ones re-run once the
    // server settles. Fire-and-forget so boot never waits on it.
    void lifecycle.reconcileOnStartup().catch(() => undefined)
    // Self-heal PATH at boot, fire-and-forget: CLI-/brew-launched servers
    // inherit whatever PATH the parent had, and a slow login-shell probe must
    // not delay the health endpoint the launching app is waiting on.
    void Effect.runPromise(agents.refreshEnvironment).catch(() => undefined)
    const server = yield* startCodevisorServer(
      {
        agents,
        auth,
        customHarnesses: customHarnessStore,
        db,
        lifecycle,
        mcp,
        nativeMcp,
        skills,
        terminal
      },
      defaultServerConfig({
        host,
        id: serverId,
        // The app launches its own server bound to 0.0.0.0 so remote clients
        // can connect; --kind lets it stay "local" despite the network bind.
        kind: kind ?? (host === "127.0.0.1" ? "local" : "remote"),
        // Network-bound servers advertise the machine's hostname so client
        // machine lists and tailnet discovery show something recognizable,
        // not the default "local" server id.
        name: args.name ?? (host === "127.0.0.1" ? "Local Codevisor" : hostname()),
        port,
        worktreeNameStyle,
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
          console.log("Codevisor server shutting down (requested by client)")
          // Let the 202 response flush before the process exits.
          setTimeout(() => process.exit(0), 250)
        },
        updater
      })
    )
    console.log(`Codevisor server listening at ${server.url}`)
  })

  return Effect.runPromise(program).catch((cause: unknown) => {
    console.error(cause instanceof Error ? cause.message : String(cause))
    process.exitCode = 1
  })
}
