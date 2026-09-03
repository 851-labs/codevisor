import { credentialFerrySources } from "@codevisor/harness-manager"
import { makeAgentRuntime, resolveShellEnv } from "@codevisor/agent-runtime"
import { makeAcpProvider, testAcpConnection } from "@codevisor/adapter-acp"
import { makeClaudeProvider } from "@codevisor/adapter-claude"
import { makeCodexProvider } from "@codevisor/adapter-codex"
import { makeCursorProvider } from "@codevisor/adapter-cursor"
import { makeGrokBuildProvider } from "@codevisor/adapter-grok-build"
import {
  makeAttachmentStore,
  makeDatabase,
  resolveServerIdentity,
  migrateAttachmentBlobs,
  worktreesRoot
} from "@codevisor/db"
import { makeTerminalManager } from "@codevisor/terminal"
import { Effect } from "effect"
import { randomUUID } from "node:crypto"
import { hostname } from "node:os"
import { dirname, join, resolve } from "node:path"
import { makeActiveWorkSleepInhibitor } from "./infra/active-work-sleep-inhibitor.js"
import {
  connectCloudBridge,
  removeCloudCredentials,
  startCloudBridge
} from "./infra/cloud-bridge.js"
import { canonicalDatabasePaths, codevisorRoot, defaultDatabasePath } from "./infra/data-dir.js"
import {
  customHarnessDefinition,
  loadCustomHarnesses,
  saveCustomHarnesses
} from "@codevisor/harness-manager"
import type { CustomHarnessLoadResult, CustomHarnessStore } from "@codevisor/harness-manager"
import { makeHarnessLifecycleManager } from "@codevisor/harness-manager"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import { acquireServerLease } from "./infra/server-lease.js"
import type { ServerLease } from "./infra/server-lease.js"
import { makeTerminalPersistence } from "./infra/terminal-persistence.js"
import { makeHarnessAuthManager } from "@codevisor/harness-manager"
import { makeMcpManager } from "@codevisor/mcp"
import { makeNativeMcpManager } from "@codevisor/mcp"
import {
  makePluginRegistryClient,
  makePluginsManager,
  managedPluginSkill,
  resolvePluginRegistryUrl
} from "@codevisor/plugins"
import { makeSkillsManager } from "@codevisor/skills"
import { migrateLegacyLayout, migrateTmpDataDir } from "./infra/legacy-layout.js"
import { makeBlobStore } from "@codevisor/sync"
import {
  SERVER_PROCESS_TITLE,
  stabilizeServerWorkingDirectory,
  failureMessage,
  initializeOptionalServerFeature,
  initializeOptionalServerFeatureAsync,
  writeDataUpgradeStatus,
  parseProcessId,
  monitorAppOwner,
  bundledVersion,
  bundledBuildMetadata,
  backgroundTerminalIntegration,
  resolveServeModes
} from "./serve-boot.js"
import { makeSelfUpdater } from "./serve-self-updater.js"
export {
  bundledBuildMetadata,
  bundledVersion,
  initializeOptionalServerFeature,
  initializeOptionalServerFeatureAsync,
  monitorAppOwner,
  parseArgs,
  stabilizeServerWorkingDirectory
} from "./serve-boot.js"
export type { BootScopedDataUpgradeProgress } from "./serve-boot.js"

/// Boots the Codevisor server from parsed `--flag value` arguments. Shared by
/// the `codevisor-server` daemon bin and the `codevisor serve` CLI subcommand.
export const runServe = (args: Record<string, string>): Promise<void> => {
  process.title = SERVER_PROCESS_TITLE
  let startupLease: ServerLease | undefined
  let stopOwnerMonitor: (() => void) | undefined
  let startupCompleted = false

  const program = Effect.gen(function* () {
    const host = args.host ?? "127.0.0.1"
    const port = Number(args.port ?? "49361")
    const worktreeNameStyle =
      process.env.CODEVISOR_DEV_INSTANCE_ID !== undefined ||
      process.env.HERDMAN_DEV_INSTANCE_ID !== undefined
        ? "development"
        : "production"
    const { authMode, directPathMode, resolvedKind } = resolveServeModes(args, host)
    const version = args.version ?? bundledVersion()
    // Resolve caller-provided paths before changing cwd below. This preserves
    // the CLI's relative-path semantics while ensuring every later consumer
    // sees an absolute path.
    const launchDirectory = process.cwd()
    const databasePath = resolve(launchDirectory, args.db ?? defaultDatabasePath())
    const requestedUpgradeStatusPath = args["upgrade-status"]
    const upgradeStatusPath =
      requestedUpgradeStatusPath === undefined
        ? join(dirname(databasePath), "data-upgrade.json")
        : resolve(launchDirectory, requestedUpgradeStatusPath)
    const bootId = args["boot-id"] ?? randomUUID()
    const serviceManaged = args["service-managed"] === "1"
    const appOwned = args["app-owned"] === "1" || serviceManaged
    const ownerPid = parseProcessId(args["owner-pid"])
    if (appOwned && !serviceManaged && ownerPid === undefined) {
      throw new Error("An app-owned server requires --owner-pid")
    }
    const buildMetadata = bundledBuildMetadata()
    // The canonical ~/.codevisor/data directory does not exist on first start
    // (unlike the old tmpdir default, which always did). It is also the
    // daemon's lifetime-stable cwd: an app-hosted server may outlive the
    // Sparkle staging bundle that launched it.
    stabilizeServerWorkingDirectory(databasePath)
    const lease = yield* Effect.tryPromise(() =>
      acquireServerLease(databasePath, {
        bootId,
        appOwned,
        waitForOwnership: appOwned
      })
    )
    startupLease = lease
    stopOwnerMonitor = ownerPid === undefined ? undefined : monitorAppOwner({ ownerPid, lease })
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
        onProgress: (progress) => writeDataUpgradeStatus(upgradeStatusPath, bootId, progress)
      })
    )
    // No server may identify as the default "local": every machine
    // publishing sync entries under one key makes the fleet LWW-merge them
    // into a single lying record — and app-hosted Macs used to do exactly
    // that, sharing one overlay key, one readiness entry, and one OAuth
    // refresh owner. Without an explicit --serverId, every kind adopts the
    // database's persisted machine identity — stable across restarts,
    // renames, and updates, minted on first boot. Rows written under the
    // former id are adopted by the database's identity upgrade.
    const serverId = args.serverId ?? `machine-${resolveServerIdentity(databasePath)}`
    const db = yield* makeDatabase({
      filename: databasePath,
      serverId,
      onDataUpgradeProgress: (progress) =>
        writeDataUpgradeStatus(upgradeStatusPath, bootId, progress)
    }).pipe(
      Effect.tapError((cause) =>
        Effect.sync(() =>
          writeDataUpgradeStatus(upgradeStatusPath, bootId, {
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
    const attachments = makeAttachmentStore(dirname(databasePath))
    yield* Effect.tryPromise({
      try: () =>
        migrateAttachmentBlobs(db, attachments, (progress) =>
          writeDataUpgradeStatus(upgradeStatusPath, bootId, progress)
        ),
      catch: (cause) =>
        cause instanceof Error ? cause : new Error(`Attachment migration failed: ${String(cause)}`)
    })
    // Self-update needs a known current version to compare against; dev runs
    // without a VERSION file simply don't offer it. The new runtime reads its
    // own bundled VERSION, so --version is not forwarded.
    const updater =
      version === undefined
        ? undefined
        : makeSelfUpdater({
            currentVersion: version,
            currentBuildNumber: buildMetadata.buildNumber,
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
              "--direct-path",
              directPathMode,
              ...(args.name === undefined ? [] : ["--name", args.name]),
              ...(args.kind === undefined ? [] : ["--kind", args.kind])
            ]
          })
    const terminal = makeTerminalManager()
    // Terminal scrollback and seq-replay survive host restarts (self-update
    // handoffs, service restarts): restore the previous process's buffers,
    // then flush on every graceful exit path.
    const terminalPersistence = makeTerminalPersistence({
      dataDir: dirname(databasePath),
      terminal,
      log: (line) => console.log(line)
    })
    terminalPersistence.restore()
    terminalPersistence.installExitHooks()
    const backgroundTerminals = yield* Effect.promise(() => backgroundTerminalIntegration(terminal))
    // Cloud relay: when this machine is connected to a Codevisor Cloud
    // account (`codevisor auth login`, or dev auto-provisioning), hold a
    // presence connection to the user's hub and serve end-to-end encrypted
    // terminal channels. Optional — local operation never depends on it.
    const cloudBridgeOptions = {
      credentialsPath: join(dirname(databasePath), "cloud.json"),
      machineName: args.name ?? hostname(),
      appVersion: version ?? "unknown",
      localBaseUrl: `http://127.0.0.1:${port}`,
      terminal,
      env: process.env,
      log: (line: string) => console.error(line)
    }
    const cloudBridge = yield* Effect.promise(() =>
      initializeOptionalServerFeatureAsync("Cloud connection", async () =>
        startCloudBridge(cloudBridgeOptions)
      )
    )
    // Live cloud registration control for /v1/cloud routes: the desktop app
    // connects/disconnects this machine as its account session changes, so a
    // signed-in Mac appears on the account without `codevisor auth login`.
    const cloudBridgeHolder: { current: typeof cloudBridge } = { current: cloudBridge }
    const cloudControl = {
      deviceId: () => cloudBridgeHolder.current?.deviceId,
      state: () => cloudBridgeHolder.current?.state(),
      managedBy: () => cloudBridgeHolder.current?.managedBy,
      connect: async (serverUrl: string, sessionToken: string) => {
        const bridge = await connectCloudBridge(cloudBridgeOptions, { serverUrl, sessionToken })
        cloudBridgeHolder.current?.stop()
        cloudBridgeHolder.current = bridge
        return bridge.deviceId
      },
      disconnect: async () => {
        cloudBridgeHolder.current?.stop()
        cloudBridgeHolder.current = undefined
        await removeCloudCredentials(cloudBridgeOptions.credentialsPath)
      },
      acceptDirect: (socket: import("@codevisor/cloud-client").CloudSocket) => {
        const bridge = cloudBridgeHolder.current
        if (bridge === undefined) return false
        bridge.acceptDirect(socket)
        return true
      }
    }
    // Start resolving the GUI process's minimal environment without delaying
    // server boot. The first Git operation awaits this shared result so
    // checkout hooks and filters can find user-installed tools such as
    // Homebrew's git-lfs.
    const gitEnvironment = resolveShellEnv()
    // User-defined custom ACP harnesses (~/.codevisor/harnesses.json) merge
    // into the catalog before anything consumes it. Bad entries are skipped
    // with a warning — a hand-edited file must never block server boot.
    const customHarnesses =
      (yield* Effect.promise(() =>
        initializeOptionalServerFeatureAsync("Custom harnesses", () =>
          loadCustomHarnesses(codevisorRoot())
        )
      )) ??
      ({
        definitions: [],
        specs: [],
        warnings: []
      } satisfies CustomHarnessLoadResult)
    for (const warning of customHarnesses.warnings) {
      console.error(`Custom harnesses: ${warning}`)
    }
    const agents = makeAgentRuntime({
      ...(backgroundTerminals === undefined ? {} : { backgroundTerminals }),
      ...(customHarnesses.definitions.length === 0
        ? {}
        : { extraHarnesses: customHarnesses.definitions }),
      providerFactories: [
        (env, context) => makeAcpProvider(env, context),
        (env, context) => makeClaudeProvider(env, context),
        (env, context) => makeCodexProvider(env, context),
        (env, context) => makeCursorProvider(env, context),
        (env, context) => makeGrokBuildProvider(env, context)
      ],
      resolveEnv: () => resolveShellEnv()
    })
    const sessionActivity = makeActiveWorkSleepInhibitor()
    const auth = initializeOptionalServerFeature("Harness authentication", () =>
      makeHarnessAuthManager({
        dataDir: dirname(databasePath),
        db,
        agents,
        terminal,
        preferDeviceCode: resolvedKind === "remote"
      })
    )
    // The static credential ferry's file layer (Phase 20): which harness
    // credential surfaces are honestly static enough to travel the fleet.
    const credentialFerry = initializeOptionalServerFeature("Credential ferry", () =>
      credentialFerrySources({ resolveEnv: () => Promise.resolve(process.env) })
    )
    const skills = initializeOptionalServerFeature("Skills", () => makeSkillsManager({ agents }))
    // Content-addressed archives the config plane replicates skills through.
    const syncBlobs = makeBlobStore(join(dirname(databasePath), "sync-blobs"))
    const pluginRegistryClient = initializeOptionalServerFeature("Plugin registry", () =>
      makePluginRegistryClient({ baseUrl: resolvePluginRegistryUrl(process.env) })
    )
    const plugins = initializeOptionalServerFeature("Plugins", () =>
      makePluginsManager({
        ...(version === undefined ? {} : { codevisorVersion: version }),
        dataDir: dirname(databasePath),
        log: (message) => console.log(message),
        // Plugin process output streams into an attachable external terminal
        // (sessionId `plugin:{id}`) so clients can offer "Show Output".
        registerExternalTerminal: (config, process) =>
          terminal.registerExternalTerminal(config, process),
        resolveEnv: () => resolveShellEnv(),
        ...(pluginRegistryClient === undefined
          ? {}
          : { fetchPluginRegistry: pluginRegistryClient.fetchIndex })
      })
    )
    // Registry browsing only makes sense where the install pipeline exists,
    // so the read-through cache over the hosted index follows the manager's
    // availability. Env overrides (or the dev cloud) rewire the base URL.
    const pluginRegistry = plugins === undefined ? undefined : pluginRegistryClient
    // Keep the plugin-authoring skill in every harness's skills directory in
    // step with feature availability, so agents can author plugins without
    // rediscovering the contract. Fire-and-forget: skill sync must never
    // block or fail server boot.
    if (skills !== undefined) {
      void Promise.resolve()
        .then(() => skills.syncManaged([managedPluginSkill(plugins !== undefined)]))
        .catch((cause: unknown) =>
          console.log(`Plugin authoring skill sync unavailable: ${failureMessage(cause)}`)
        )
    }
    const mcp = initializeOptionalServerFeature("MCP", () =>
      makeMcpManager({
        db,
        dataDir: dirname(databasePath),
        serverId,
        serverKind: resolvedKind,
        ...(skills === undefined ? {} : { syncManagedSkills: skills.syncManaged }),
        // Installed plugins' declared tools surface to agents through the MCP
        // gateway (server "plugin"); the plugins manager satisfies the mcp
        // package's structural PluginToolSource seam as-is.
        ...(plugins === undefined ? {} : { pluginTools: plugins })
      })
    )
    const nativeMcp =
      mcp === undefined
        ? undefined
        : initializeOptionalServerFeature("Native MCP discovery", () =>
            makeNativeMcpManager({
              agents,
              dataDir: dirname(databasePath),
              db,
              mcp
            })
          )
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
    const lifecycle = initializeOptionalServerFeature("Harness lifecycle", () => {
      const manager = makeHarnessLifecycleManager({
        agents,
        db,
        resolveEnv: () => resolveShellEnv(),
        terminal
      })
      // Periodic harness update detection — jittered start, 6h cadence. The
      // stop handle is intentionally dropped: checks live for the process.
      manager.startPeriodicChecks()
      return manager
    })
    // Interrupted updates become failures; still-armed ones re-run once the
    // server settles. Fire-and-forget so boot never waits on it.
    void lifecycle?.reconcileOnStartup().catch(() => undefined)
    // Self-heal PATH at boot, fire-and-forget: CLI-/brew-launched servers
    // inherit whatever PATH the parent had, and a slow login-shell probe must
    // not delay the health endpoint the launching app is waiting on.
    void Effect.runPromise(agents.refreshEnvironment).catch(() => undefined)
    const server = yield* startCodevisorServer(
      {
        agents,
        attachments,
        customHarnesses: customHarnessStore,
        db,
        resolveGitEnvironment: () => gitEnvironment,
        terminal,
        ...(auth === undefined ? {} : { auth }),
        ...(lifecycle === undefined ? {} : { lifecycle }),
        ...(credentialFerry === undefined ? {} : { credentialFerry }),
        ...(mcp === undefined ? {} : { mcp }),
        ...(nativeMcp === undefined ? {} : { nativeMcp }),
        ...(plugins === undefined ? {} : { plugins }),
        ...(pluginRegistry === undefined ? {} : { pluginRegistry }),
        ...(skills === undefined ? {} : { skills }),
        syncBlobs
      },
      defaultServerConfig({
        host,
        id: serverId,
        // The app launches its own server bound to 0.0.0.0 so remote clients
        // can connect; --kind lets it stay "local" despite the network bind.
        kind: resolvedKind,
        // Network-bound servers advertise the machine's hostname so client
        // machine lists and tailnet discovery show something recognizable,
        // not the default "local" server id.
        name: args.name ?? (host === "127.0.0.1" ? "Local Codevisor" : hostname()),
        port,
        directPathEnabled: directPathMode === "enabled",
        worktreeNameStyle,
        // Lets clients match this machine to its cloud presence entry, and
        // drive its registration live via /v1/cloud as the app's account
        // session changes.
        cloud: cloudControl,
        bootId,
        processId: process.pid,
        appOwned,
        serviceManaged,
        ...buildMetadata,
        ...(version === undefined ? {} : { version }),
        auth: {
          // Same-machine clients (the app that launched this server, the
          // terminal proxy) are trusted without a token; only connections
          // arriving over the network must present one.
          allowLocalhostWithoutAuth: authMode === "token",
          requireBearerToken: authMode === "token"
        },
        restartSnapshotPath: join(dirname(databasePath), "restart-resume.json"),
        onShutdownRequested: () => {
          console.log("Codevisor server shutting down (requested by client)")
          stopOwnerMonitor?.()
          // Let the 202 response flush before the process exits.
          setTimeout(() => {
            void lease.release().finally(() => process.exit(0))
          }, 250)
        },
        sessionActivity,
        updater
      })
    )
    startupCompleted = true
    console.log(`Codevisor server listening at ${server.url}`)
    // Installed plugins are server companions: start them only after the
    // main listener is ready, without letting one broken plugin delay or
    // fail Codevisor startup. The manager keeps crashed processes running
    // again behind its own backoff/circuit breaker.
    void plugins
      ?.startAll()
      .catch((cause: unknown) =>
        console.log(`Plugin startup unavailable: ${failureMessage(cause)}`)
      )
  })

  return Effect.runPromise(program).catch(async (cause: unknown) => {
    stopOwnerMonitor?.()
    if (!startupCompleted) {
      await startupLease?.release().catch(() => undefined)
    }
    console.error(failureMessage(cause))
    // This is a dedicated server process. Startup may already have opened
    // long-lived helpers (for example the background-terminal Unix socket), so
    // exitCode alone can leave an inert process alive indefinitely.
    process.exit(1)
  })
}
