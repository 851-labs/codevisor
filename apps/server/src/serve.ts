import { execFile } from "node:child_process"
import { homedir, hostname } from "node:os"
import { dirname, join, resolve } from "node:path"
import { promisify } from "node:util"

import { makeAgentRuntime, makeShellEnvCache, resolveShellEnv } from "@codevisor/agent-runtime"
import type { DataUpgradeProgress } from "@codevisor/api"
import {
  makeAttachmentStore,
  makeDatabase,
  resolveServerIdentity,
  migrateAttachmentBlobs,
  worktreesRoot
} from "@codevisor/db"
import { credentialFerrySources } from "@codevisor/harness-manager"
import { makeHarnessLifecycleManager } from "@codevisor/harness-manager"
import { makeHarnessAuthManager } from "@codevisor/harness-manager"
import { makeMcpManager } from "@codevisor/mcp"
import {
  makePluginRegistryClient,
  makePluginsManager,
  pluginAuthoringSkill,
  resolvePluginRegistryUrl
} from "@codevisor/plugins"
import { attachingFilesSkill, makeSkillStore, migrateLegacySkills } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { makeTerminalManager } from "@codevisor/terminal"
import { Effect } from "effect"

import { agentProviderFactories } from "./agent-providers.js"
import {
  FAILED_UPGRADE_GRACE_MS,
  startBootListenerIfPortFree,
  type BootListener
} from "./boot-listener.js"
import { makeActiveWorkSleepInhibitor } from "./infra/active-work-sleep-inhibitor.js"
import { canonicalDatabasePaths, resolveServerDataLayout } from "./infra/data-dir.js"
import { migrateLegacyLayout, migrateTmpDataDir } from "./infra/legacy-layout.js"
import { migrateLinuxDataLayout } from "./infra/linux-data-migration.js"
import { guessMachineIcon } from "./infra/machine-icon.js"
import { makeOpenCodeSetup, openCodeAccountContexts } from "./infra/opencode-setup.js"
import { acquireServerLease, type ServerLease } from "./infra/server-lease.js"
import { makeSharedAccounts, type SharedAccounts } from "./infra/shared-accounts.js"
import { makeAppIconLoader } from "./infra/tool-icon-apps.js"
import { makeToolIconStore } from "./infra/tool-icons.js"
import {
  restoreTerminalPersistence,
  screenSharingProvider,
  simulatorsProvider,
  startMachineNetwork,
  systemNativeMcpManager
} from "./serve-boot.js"
import {
  SERVER_PROCESS_TITLE,
  stabilizeServerWorkingDirectory,
  failureMessage,
  initializeOptionalServerFeature,
  writeDataUpgradeStatus,
  parseProcessId,
  monitorAppOwner,
  bundledVersion,
  bundledBuildMetadata,
  resolveServeModes,
  selfUpdateServeArgs,
  databaseStartupFailure
} from "./serve-boot.js"
import { makeSelfUpdater } from "./serve-self-updater.js"
import { sweepTrashedWorktrees } from "./server-workspace-effects.js"
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
    if (args.db === undefined || canonicalDatabasePaths().includes(databasePath)) {
      yield* Effect.tryPromise(() => migrateTmpDataDir({ databasePath }))
    }
    yield* Effect.tryPromise(() =>
      migrateLegacyLayout({
        databasePath,
        worktreesRoot: worktreesRoot(),
        homeDirectory: homedir(),
        onProgress: reportUpgrade,
        log: (message) => console.error(message)
      })
    )
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
    const machineName = args.name ?? hostname()
    const iconGuess = guessMachineIcon()
    const { cloudControl, machine, machineLink, machineEnrollment } = yield* Effect.promise(() =>
      startMachineNetwork({
        databasePath,
        port,
        serverId,
        machineName,
        icon: iconGuess,
        version,
        db
      })
    )
    const icon = yield* Effect.promise(() => iconGuess)
    const shellEnv = makeShellEnvCache(() => resolveShellEnv())
    const gitEnvironment = shellEnv.current()
    const agents = makeAgentRuntime({
      providerFactories: agentProviderFactories,
      resolveEnv: shellEnv.refresh,
      resolveDirectoryEnv: (cwd) => resolveShellEnv({ cwd })
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
        preferDeviceCode: resolvedKind === "remote",
        resolveEnv: shellEnv.current
      })
    )
    if (auth)
      sharedAccounts = makeSharedAccounts({
        db,
        auth,
        dataDir: dirname(databasePath),
        serverId,
        baseUrl: `http://127.0.0.1:${port}`,
        environment: shellEnv.current
      })
    const credentialFerry = initializeOptionalServerFeature("Credential ferry", () =>
      credentialFerrySources({
        resolveEnv: () => Promise.resolve(process.env),
        localProviders: async (harness) =>
          (await sharedAccounts?.providers.staticOverrides(harness)) ?? []
      })
    )
    const skillsDir = join(dirname(databasePath), "skills")
    const skillsEnv = { agents, env: process.env, homedir: homedir() }
    const skills = initializeOptionalServerFeature("Skills", () =>
      makeSkillStore({ dir: skillsDir })
    )
    if (skills !== undefined)
      void migrateLegacySkills({ ...skillsEnv, storeDir: skillsDir }).catch((cause: unknown) =>
        console.log(`Skill migration failed: ${failureMessage(cause)}`)
      )
    const syncBlobs = makeBlobStore(join(dirname(databasePath), "sync-blobs"))
    const pluginRegistryClient = initializeOptionalServerFeature("Plugin registry", () =>
      makePluginRegistryClient({ baseUrl: resolvePluginRegistryUrl(process.env) })
    )
    const plugins = initializeOptionalServerFeature("Plugins", () =>
      makePluginsManager({
        ...(version === undefined ? {} : { codevisorVersion: version }),
        dataDir: dirname(databasePath),
        log: (message) => console.log(message),
        registerExternalTerminal: (config, process) =>
          terminal.registerExternalTerminal(config, process),
        resolveEnv: () => resolveShellEnv(),
        ...(pluginRegistryClient === undefined
          ? {}
          : { fetchPluginRegistry: pluginRegistryClient.fetchIndex })
      })
    )
    const pluginRegistry = plugins === undefined ? undefined : pluginRegistryClient
    const packagedSkills = [
      initializeOptionalServerFeature("File delivery skill", attachingFilesSkill),
      plugins && initializeOptionalServerFeature("Plugin skill", () => pluginAuthoringSkill())
    ].filter((skill) => skill !== undefined)
    const mcp = initializeOptionalServerFeature("MCP", () =>
      makeMcpManager({
        db,
        dataDir: dirname(databasePath),
        serverId,
        machine,
        remoteInvoker: machineLink.invoke,
        serverKind: resolvedKind,
        packagedSkills,
        ...(skills === undefined ? {} : { skillSource: skills }),
        ...(plugins === undefined ? {} : { pluginTools: plugins })
      })
    )
    const nativeMcp =
      mcp === undefined
        ? undefined
        : initializeOptionalServerFeature("Native MCP discovery", () =>
            systemNativeMcpManager({ agents, dataDir: dirname(databasePath), db, mcp })
          )
    const lifecycle = initializeOptionalServerFeature("Harness lifecycle", () => {
      const manager = makeHarnessLifecycleManager({
        agents,
        db,
        harnessSetup: {
          opencode: makeOpenCodeSetup(
            auth === undefined ? {} : { accounts: openCodeAccountContexts(auth) }
          )
        },
        resolveEnv: () => resolveShellEnv(),
        terminal
      })
      manager.startPeriodicChecks()
      return manager
    })
    void lifecycle?.reconcileOnStartup().catch(() => undefined)
    void lifecycle?.finishPendingSetup().catch(() => undefined)
    void Effect.runPromise(agents.refreshEnvironment).catch(() => undefined)
    void sweepTrashedWorktrees()
    startup.checkpoint("checkingHealth")
    const server = yield* startCodevisorServer(
      {
        agents,
        attachments,
        db,
        resolveGitEnvironment: (directory) =>
          directory === undefined ? gitEnvironment : resolveShellEnv({ cwd: directory }),
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
        syncBlobs,
        toolIcons: makeToolIconStore({
          dir: join(dirname(databasePath), "tool-icons"),
          ...(process.platform === "darwin" ? { appIcon: makeAppIconLoader() } : {}),
          ...(mcp === undefined ? {} : { mcpSources: mcp.iconSources })
        }),
        machines: machineLink,
        machineEnrollment
      },
      defaultServerConfig({
        host,
        id: serverId,
        kind: resolvedKind,
        name: args.name ?? (host === "127.0.0.1" ? "Local Codevisor" : hostname()),
        port,
        directPathEnabled: directPathMode === "enabled",
        worktreeNameStyle,
        cloud: cloudControl,
        workspaceGit: true,
        icon,
        bootId,
        processId: process.pid,
        appOwned,
        serviceManaged,
        ...buildMetadata,
        ...(version === undefined ? {} : { version }),
        auth: {
          allowLocalhostWithoutAuth: authMode === "token",
          requireBearerToken: authMode === "token"
        },
        restartSnapshotPath: join(dirname(databasePath), "restart-resume.json"),
        onShutdownRequested: () => {
          console.log("Codevisor server shutting down (requested by client)")
          stopOwnerMonitor?.()
          setTimeout(() => {
            void lease.release().finally(() => process.exit(0))
          }, 250)
        },
        sessionActivity,
        ...screenSharingProvider(dirname(databasePath)),
        simulators: simulatorsProvider(dirname(databasePath)),
        updater
      }),
      bootListener
    )
    bootListener = undefined
    startupCompleted = true
    startup.checkpoint("ready")
    console.log(`Codevisor server listening at ${server.url}`)
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
    await bootListener?.close(upgradeFailed ? { afterMs: FAILED_UPGRADE_GRACE_MS } : undefined)
    process.exit(1)
  })
}
