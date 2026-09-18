import { execFile } from "node:child_process"
import { hostname } from "node:os"
import { dirname, join, resolve } from "node:path"
import { promisify } from "node:util"

import { makeAcpProvider } from "@codevisor/adapter-acp"
import { makeClaudeProvider } from "@codevisor/adapter-claude"
import { makeCodexProvider } from "@codevisor/adapter-codex"
import { makeCursorProvider } from "@codevisor/adapter-cursor"
import { makeGrokBuildProvider } from "@codevisor/adapter-grok-build"
import { makeAgentRuntime, resolveShellEnv } from "@codevisor/agent-runtime"
import type { DataUpgradeProgress } from "@codevisor/api"
import {
  makeAttachmentStore,
  makeDatabase,
  resolveServerIdentity,
  migrateAttachmentBlobs,
  worktreesRoot
} from "@codevisor/db"
import { credentialFerrySources } from "@codevisor/harness-manager"
import { loadCustomHarnesses } from "@codevisor/harness-manager"
import type { CustomHarnessLoadResult } from "@codevisor/harness-manager"
import { makeHarnessLifecycleManager } from "@codevisor/harness-manager"
import { makeHarnessAuthManager } from "@codevisor/harness-manager"
import { makeMcpManager, makeNativeMcpManager } from "@codevisor/mcp"
import {
  makePluginRegistryClient,
  makePluginsManager,
  managedPluginSkill,
  resolvePluginRegistryUrl
} from "@codevisor/plugins"
import { makeSkillsManager, managedAttachmentSkill } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { makeTerminalManager } from "@codevisor/terminal"
import { Effect } from "effect"

import {
  FAILED_UPGRADE_GRACE_MS,
  startBootListenerIfPortFree,
  type BootListener
} from "./boot-listener.js"
import { makeActiveWorkSleepInhibitor } from "./infra/active-work-sleep-inhibitor.js"
import { makeCloudServerControl, startCloudBridge } from "./infra/cloud-bridge.js"
import { makeCustomHarnessStore } from "./infra/custom-harness-store.js"
import { canonicalDatabasePaths, codevisorRoot, resolveServerDataLayout } from "./infra/data-dir.js"
import { migrateLegacyLayout, migrateTmpDataDir } from "./infra/legacy-layout.js"
import { migrateLinuxDataLayout } from "./infra/linux-data-migration.js"
import { acquireServerLease, type ServerLease } from "./infra/server-lease.js"
import { makeSharedAccounts, type SharedAccounts } from "./infra/shared-accounts.js"
import { restoreTerminalPersistence, screenSharingProvider } from "./serve-boot.js"
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
  resolveServeModes,
  selfUpdateServeArgs,
  databaseStartupFailure
} from "./serve-boot.js"
import { makeSelfUpdater } from "./serve-self-updater.js"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import { makeStartupReporter, type StartupReporter } from "./startup-progress.js"
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
export const runServe = (
  args: Record<string, string>,
  startup: StartupReporter = makeStartupReporter(args)
): Promise<void> => {
  startup.checkpoint("acquiringDatabase")
  process.title = SERVER_PROCESS_TITLE
  let startupLease: ServerLease | undefined
  let stopOwnerMonitor: (() => void) | undefined
  let startupCompleted = false
  let bootListener: BootListener | undefined
  let upgradeFailed = false

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
    const layout = resolveServerDataLayout(args.db)
    const databasePath = layout.databasePath
    const requestedUpgradeStatusPath = args["upgrade-status"]
    const upgradeStatusPath =
      requestedUpgradeStatusPath === undefined
        ? join(dirname(databasePath), "data-upgrade.json")
        : resolve(launchDirectory, requestedUpgradeStatusPath)
    const bootId = args["boot-id"]!
    const reportUpgrade = (progress: DataUpgradeProgress): void => {
      writeDataUpgradeStatus(upgradeStatusPath, bootId, progress)
      bootListener?.report(progress)
      if (progress.state === "running") startup.work(progress)
      if (progress.state === "failed") upgradeFailed = true
    }
    const serviceManaged = args["service-managed"] === "1"
    const appOwned = args["app-owned"] === "1" || serviceManaged
    const ownerPid = parseProcessId(args["owner-pid"])
    if (appOwned && !serviceManaged && ownerPid === undefined) {
      throw new Error("An app-owned server requires --owner-pid")
    }
    const buildMetadata = bundledBuildMetadata()
    yield* Effect.tryPromise(() =>
      migrateLinuxDataLayout({
        layout,
        bootId,
        servicePath: "/etc/systemd/system/codevisor-server.service",
        reloadService: async () => {
          await promisify(execFile)("systemctl", ["daemon-reload"])
        },
        log: (message) => console.error(message)
      })
    )
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
    // Answer /v1/health while the blocking data upgrades below run, so a
    // remote client can follow "updating chat history, 40%" instead of
    // seeing a refused connection.
    bootListener = yield* Effect.promise(() =>
      startBootListenerIfPortFree({
        host,
        port,
        version,
        bootId,
        processId: process.pid,
        appOwned,
        serviceManaged,
        ...buildMetadata
      })
    )
    startup.checkpoint("openingDatabase")
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
        onProgress: reportUpgrade
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
      onDataUpgradeProgress: reportUpgrade
    }).pipe(
      Effect.tapError((cause) =>
        Effect.sync(() => reportUpgrade(databaseStartupFailure(cause.message)))
      )
    )
    const attachments = makeAttachmentStore(dirname(databasePath))
    yield* Effect.tryPromise({
      try: () => migrateAttachmentBlobs(db, attachments, reportUpgrade),
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
            serveArgs: selfUpdateServeArgs({
              host,
              port,
              databasePath,
              serverId,
              authMode,
              directPathMode,
              name: args.name,
              kind: args.kind
            })
          })
    startup.checkpoint("restoringTerminals")
    const terminal = makeTerminalManager()
    restoreTerminalPersistence(dirname(databasePath), terminal, startup)
    startup.checkpoint("initializingServices")
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
    const cloudControl = makeCloudServerControl(cloudBridgeOptions, cloudBridge)
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
    let sharedAccounts: SharedAccounts | undefined
    const auth = initializeOptionalServerFeature("Harness authentication", () =>
      makeHarnessAuthManager({
        sharedAccounts: () => sharedAccounts,
        sharedProviders: () => sharedAccounts?.providers,
        dataDir: dirname(databasePath),
        db,
        agents,
        terminal,
        preferDeviceCode: resolvedKind === "remote"
      })
    )
    if (auth)
      sharedAccounts = makeSharedAccounts({
        db,
        auth,
        dataDir: dirname(databasePath),
        serverId,
        baseUrl: `http://127.0.0.1:${port}`
      })
    // Sync static credentials without overwriting machine-specific providers.
    const credentialFerry = initializeOptionalServerFeature("Credential ferry", () =>
      credentialFerrySources({
        resolveEnv: () => Promise.resolve(process.env),
        localProviders: async (harness) =>
          (await sharedAccounts?.providers.staticOverrides(harness)) ?? []
      })
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
    // File delivery is available in every harness independently of optional
    // tools. Plugin authoring follows feature availability. Skill sync must
    // never block or fail server boot.
    if (skills !== undefined) {
      void Promise.resolve()
        .then(() =>
          skills.syncManaged([managedAttachmentSkill(), managedPluginSkill(plugins !== undefined)])
        )
        .catch((cause: unknown) =>
          console.log(`Managed skill sync unavailable: ${failureMessage(cause)}`)
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
    const customHarnessStore = makeCustomHarnessStore(agents)
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
    startup.checkpoint("checkingHealth")
    const server = yield* startCodevisorServer(
      {
        agents,
        attachments,
        customHarnesses: customHarnessStore,
        db,
        resolveGitEnvironment: () => gitEnvironment,
        terminal,
        ...(auth === undefined ? {} : { auth }),
        ...(sharedAccounts === undefined ? {} : { sharedAccounts }),
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
        ...screenSharingProvider(dirname(databasePath)),
        updater
      }),
      bootListener
    )
    // The real server owns the socket now.
    bootListener = undefined
    startupCompleted = true
    startup.checkpoint("ready")
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
    startup.fail(new Error(failureMessage(cause)))
    stopOwnerMonitor?.()
    if (!startupCompleted) {
      await startupLease?.release().catch(() => undefined)
    }
    console.error(failureMessage(cause))
    // A failed data upgrade stays readable for a moment (see BootListener.close).
    await bootListener?.close(upgradeFailed ? { afterMs: FAILED_UPGRADE_GRACE_MS } : undefined)
    // Startup may have opened long-lived helpers; setting exitCode alone
    // would leave this dedicated server process alive indefinitely.
    process.exit(1)
  })
}
