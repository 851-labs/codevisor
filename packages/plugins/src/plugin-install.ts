import { lstat, rename, rm } from "node:fs/promises"
import { basename, join } from "node:path"

import type {
  DiscoverRemotePluginRequest,
  DiscoverRemotePluginResult,
  ImportRemotePluginRequest,
  LinkPluginRequest,
  PluginManifest
} from "@codevisor/api"

import { makePluginCandidatePreparer } from "./plugin-candidate.js"
import { displayPluginCommand, pluginSetupCommands } from "./plugin-command.js"
import { describePlugin } from "./plugin-discovery.js"
import type {
  PreparedPluginUpdate,
  PreparePluginUpdateRequest,
  StagedPlugin
} from "./plugin-install-types.js"
import { linkPlugin, unlinkPlugin, type PluginLinkDeps } from "./plugin-link.js"
import { readPluginInstallReceipt } from "./plugin-receipt.js"
import type { FindExecutable } from "./plugin-requirements.js"
import { makePluginRestore, type PluginRestore } from "./plugin-restore.js"
import { clonePluginSource, type ClonePluginSourceResult } from "./plugin-source.js"
import { isPluginPathSafe, stagePluginSource } from "./plugin-staging.js"
import { scanPlugins, type InstalledPlugin } from "./plugin-store.js"
import type {
  PluginProcessHandle,
  PluginSpawnOptions,
  RegisterPluginTerminal
} from "./plugin-supervisor.js"
import { defaultSpawnArgv, defaultSpawnShell } from "./plugin-supervisor.js"
import { makePluginTransactionEngine } from "./plugin-transaction.js"
import { PluginsError } from "./plugins-error.js"

export interface PluginInstallerDeps {
  readonly pluginsRoot: string
  readonly spawnShell?: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
  readonly spawnArgv?: (
    argv: ReadonlyArray<string>,
    options: PluginSpawnOptions
  ) => PluginProcessHandle
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly clone?: (
    url: string,
    ref: string | undefined,
    destination: string,
    env: NodeJS.ProcessEnv
  ) => Promise<ClonePluginSourceResult>
  readonly findExecutable?: FindExecutable
  readonly platform?: string
  readonly codevisorVersion?: string
  readonly receiptNow?: () => Date
  readonly pluginDataRoot: string
  readonly verifyInstalled: (pluginId: string) => Promise<void>
  readonly registerExternalTerminal?: RegisterPluginTerminal | undefined
  readonly stop: (pluginId: string) => void
}

export interface PluginInstaller extends PluginRestore {
  readonly discoverRemote: (
    request: DiscoverRemotePluginRequest
  ) => Promise<DiscoverRemotePluginResult>
  readonly importRemote: (request: ImportRemotePluginRequest) => Promise<PluginManifest>
  readonly prepareUpdate: (request: PreparePluginUpdateRequest) => Promise<PreparedPluginUpdate>
  readonly applyPreparedUpdate: (prepared: PreparedPluginUpdate) => Promise<PluginManifest>
  readonly discardPreparedUpdate: (prepared: PreparedPluginUpdate) => Promise<void>
  readonly recover: () => Promise<void>
  readonly remove: (pluginId: string) => Promise<void>
  readonly link: (request: LinkPluginRequest) => Promise<PluginManifest>
  readonly unlink: (pluginId: string) => Promise<void>
}

export const makePluginInstaller = (deps: PluginInstallerDeps): PluginInstaller => {
  const clone = deps.clone ?? clonePluginSource
  const spawnShell = deps.spawnShell ?? defaultSpawnShell
  const spawnArgv = deps.spawnArgv ?? defaultSpawnArgv
  const resolveEnv = deps.resolveEnv ?? (() => Promise.resolve(process.env))
  const stagingDeps = { clone, resolveEnv, findExecutable: deps.findExecutable }
  const platform = deps.platform ?? process.platform
  const receiptNow = deps.receiptNow ?? (() => new Date())
  const transactions = makePluginTransactionEngine({
    pluginDataRoot: deps.pluginDataRoot,
    pluginsRoot: deps.pluginsRoot,
    stop: deps.stop,
    verifyInstalled: deps.verifyInstalled
  })
  const updatePlansRoot = join(deps.pluginsRoot, ".codevisor-update-plans")

  const installedWithId = (pluginId: string): InstalledPlugin | undefined =>
    scanPlugins(deps.pluginsRoot).plugins.find((candidate) => candidate.id === pluginId)
  const restore = makePluginRestore({ installedWithId, transactions })

  const managedDirectory = (pluginId: string): string => {
    const destination = join(deps.pluginsRoot, pluginId)
    /* v8 ignore next 3 */
    if (basename(destination) !== pluginId || !isPluginPathSafe(deps.pluginsRoot, destination)) {
      throw new PluginsError("invalid", `Invalid plugin directory name: ${pluginId}`)
    }
    return destination
  }

  const runSetupCommand = (
    command: ReturnType<typeof pluginSetupCommands>[number],
    manifest: PluginManifest,
    directory: string,
    env: NodeJS.ProcessEnv
  ): Promise<{ readonly ok: boolean; readonly message: string }> =>
    new Promise((resolvePromise) => {
      const child =
        command.kind === "shell"
          ? spawnShell(command.command, { cwd: directory, env })
          : spawnArgv(command.argv, { cwd: directory, env })
      const terminal = deps.registerExternalTerminal?.(
        { normalizeNewlines: true, sessionId: `plugin-install:${manifest.id}` },
        { kill: () => child.kill(), resize: () => undefined, write: () => undefined }
      )
      terminal?.output(`$ ${displayPluginCommand(command)}\r\n`)
      child.onOutput?.((data) => terminal?.output(data))
      child.onExit((message, exitCode) => {
        terminal?.exit(exitCode ?? undefined)
        resolvePromise({ message, ok: exitCode === 0 })
      })
    })

  const runSetup = async (
    manifest: PluginManifest,
    directory: string,
    baseEnv: NodeJS.ProcessEnv,
    previousVersion: string | undefined
  ): Promise<void> => {
    const env: NodeJS.ProcessEnv = {
      ...baseEnv,
      CODEVISOR_PLUGIN_ID: manifest.id,
      CODEVISOR_PLUGIN_INSTALL_REASON: previousVersion === undefined ? "install" : "update",
      CODEVISOR_PLUGIN_VERSION: manifest.version,
      ...(previousVersion === undefined
        ? {}
        : { CODEVISOR_PLUGIN_PREVIOUS_VERSION: previousVersion })
    }
    for (const command of pluginSetupCommands(manifest, platform)) {
      const outcome = await runSetupCommand(command, manifest, directory, env)
      if (!outcome.ok) {
        throw new PluginsError(
          "invalid",
          `Plugin ${manifest.id} setup command failed: ${outcome.message}`
        )
      }
    }
  }

  const candidates = makePluginCandidatePreparer({
    installedWithId,
    managedDirectory,
    platform,
    pluginsRoot: deps.pluginsRoot,
    receiptNow,
    runSetup,
    ...(deps.codevisorVersion === undefined ? {} : { codevisorVersion: deps.codevisorVersion }),
    ...(deps.findExecutable === undefined ? {} : { findExecutable: deps.findExecutable })
  })

  const preparedDirectory = (pluginId: string, planId: string): string => {
    if (!/^[0-9a-z-]{1,128}$/i.test(planId)) {
      throw new PluginsError("invalid", `Invalid plugin update plan id: ${planId}`)
    }
    const directory = join(updatePlansRoot, `${pluginId}.${planId}`)
    /* v8 ignore next 3 */
    if (!isPluginPathSafe(updatePlansRoot, directory)) {
      throw new PluginsError("invalid", `Invalid plugin update plan path: ${planId}`)
    }
    return directory
  }

  const importStaged = async (staged: StagedPlugin): Promise<void> => {
    await transactions.withLock(staged.manifest.id, async () => {
      await transactions.recoverPlugin(staged.manifest.id)
      const transactionPaths = transactions.paths(staged.manifest.id)
      try {
        const context = await candidates.prepare(staged, transactionPaths.candidate, false)
        await transactions.apply(staged.manifest.id, context.hadExisting)
      } catch (cause) {
        await rm(transactionPaths.candidate, { force: true, recursive: true })
        throw cause
      }
    })
  }

  const linkDeps: PluginLinkDeps = {
    pluginsRoot: deps.pluginsRoot,
    stop: deps.stop,
    installedWithId,
    managedDirectory,
    withLock: transactions.withLock,
    recoverPlugin: transactions.recoverPlugin
  }

  return {
    ...restore,
    discoverRemote: async (request) => {
      const staged = await stagePluginSource(request.source, stagingDeps)
      try {
        const { manifest } = staged
        return describePlugin(
          manifest,
          staged.source,
          platform,
          installedWithId(manifest.id) !== undefined
        )
      } finally {
        await staged.cleanup()
      }
    },
    importRemote: async (request) => {
      const staged = await stagePluginSource(request.source, stagingDeps)
      try {
        await importStaged(staged)
        return staged.manifest
      } finally {
        await staged.cleanup()
      }
    },
    prepareUpdate: async (request) => {
      const staged = await stagePluginSource(request.source, stagingDeps, request.sourceReceipt)
      try {
        if (staged.manifest.id !== request.expectedPluginId) {
          throw new PluginsError(
            "invalid",
            `Registry update for ${request.expectedPluginId} provided manifest id ${staged.manifest.id}`
          )
        }
        return await transactions.withLock(staged.manifest.id, async () => {
          await transactions.recoverPlugin(staged.manifest.id)
          const directory = preparedDirectory(staged.manifest.id, request.planId)
          try {
            const context = await candidates.prepare(staged, directory, true)
            if (context.previousManifest === undefined || context.previousReceipt === undefined) {
              throw new PluginsError(
                "conflict",
                `Plugin ${staged.manifest.id} has no trusted install receipt; reinstall it before updating`
              )
            }
            return {
              directory,
              manifest: staged.manifest,
              planId: request.planId,
              pluginId: staged.manifest.id,
              previousManifest: context.previousManifest,
              previousResolvedCommit: context.previousReceipt.resolvedCommit,
              resolvedCommit: staged.resolvedCommit
            }
          } catch (cause) {
            await rm(directory, { force: true, recursive: true })
            throw cause
          }
        })
      } finally {
        await staged.cleanup()
      }
    },
    applyPreparedUpdate: async (prepared) =>
      transactions.withLock(prepared.pluginId, async () => {
        await transactions.recoverPlugin(prepared.pluginId)
        if (prepared.directory !== preparedDirectory(prepared.pluginId, prepared.planId)) {
          throw new PluginsError("invalid", "Plugin update plan directory is not trusted")
        }
        const existing = installedWithId(prepared.pluginId)
        const receipt = readPluginInstallReceipt(managedDirectory(prepared.pluginId))
        if (
          existing?.manifest.version !== prepared.previousManifest.version ||
          receipt?.resolvedCommit !== prepared.previousResolvedCommit
        ) {
          throw new PluginsError(
            "conflict",
            `Plugin ${prepared.pluginId} changed after this update was prepared; prepare a new plan`
          )
        }
        const transactionPaths = transactions.paths(prepared.pluginId)
        await rm(transactionPaths.candidate, { force: true, recursive: true })
        try {
          await rename(prepared.directory, transactionPaths.candidate)
        } catch {
          throw new PluginsError(
            "notFound",
            `Plugin update plan is missing or expired: ${prepared.planId}`
          )
        }
        await transactions.apply(prepared.pluginId, true)
        return prepared.manifest
      }),
    discardPreparedUpdate: async (prepared) => {
      if (prepared.directory !== preparedDirectory(prepared.pluginId, prepared.planId)) {
        throw new PluginsError("invalid", "Plugin update plan directory is not trusted")
      }
      await rm(prepared.directory, { force: true, recursive: true })
    },
    recover: async () => {
      await transactions.recover()
      await rm(updatePlansRoot, { force: true, recursive: true })
    },
    link: (request) => linkPlugin(linkDeps, request),
    unlink: (pluginId) => unlinkPlugin(linkDeps, pluginId),
    remove: async (pluginId) => {
      await transactions.withLock(pluginId, async () => {
        await transactions.recoverPlugin(pluginId)
        const plugin = installedWithId(pluginId)
        if (plugin === undefined) {
          throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
        }
        const stats = await lstat(plugin.path)
        if (stats.isSymbolicLink() || plugin.source !== "managed") {
          throw new PluginsError(
            "invalid",
            `Plugin ${pluginId} is linked, not managed — remove the link from ${deps.pluginsRoot} yourself`
          )
        }
        deps.stop(pluginId)
        await rm(plugin.path, { force: true, recursive: true })
        const transactionPaths = transactions.paths(pluginId)
        await rm(transactionPaths.knownGoodCode, { force: true, recursive: true })
        await rm(transactionPaths.knownGoodData, { force: true, recursive: true })
      })
    }
  }
}
