import type {
  DiscoverRemotePluginRequest,
  DiscoverRemotePluginResult,
  ImportRemotePluginRequest,
  LinkPluginRequest,
  PluginManifest
} from "@codevisor/api"
import { lstat, mkdir, mkdtemp, readFile, rename, rm, stat, symlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, isAbsolute, join, normalize, resolve, sep } from "node:path"
import { displayPluginCommand, pluginRunCommand, pluginSetupCommands } from "./plugin-command.js"
import { makePluginCandidatePreparer } from "./plugin-candidate.js"
import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import { readPluginInstallReceipt, type PluginInstallSourceReceipt } from "./plugin-receipt.js"
import { assertGitAvailable, type FindExecutable } from "./plugin-requirements.js"
import {
  clonePluginSource,
  parsePluginSource,
  type ClonePluginSourceResult,
  type ParsedPluginSource
} from "./plugin-source.js"
import { scanPlugins, type InstalledPlugin } from "./plugin-store.js"
import type {
  PluginProcessHandle,
  PluginSpawnOptions,
  RegisterPluginTerminal
} from "./plugin-supervisor.js"
import { defaultSpawnArgv, defaultSpawnShell } from "./plugin-supervisor.js"
import { PluginsError } from "./plugins-error.js"
import { makePluginTransactionEngine } from "./plugin-transaction.js"
import type {
  PreparedPluginUpdate,
  PreparePluginUpdateRequest,
  StagedPlugin
} from "./plugin-install-types.js"

/// The install pipeline behind `codevisor plugin install|link|remove` and the
/// matching /v1/plugins routes, forked from packages/skills' staged-clone
/// approach: stage the source into a mkdtemp clone, read the manifest there,
/// and only then touch the plugins root. All effects run through injectable
/// seams (clone, spawnShell, registerExternalTerminal) so tests never hit the
/// network or spawn real installs.
export interface PluginInstallerDeps {
  readonly pluginsRoot: string
  /// Runs the manifest install command (login shell, cwd = plugin dir).
  readonly spawnShell?: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
  readonly spawnArgv?: (
    argv: ReadonlyArray<string>,
    options: PluginSpawnOptions
  ) => PluginProcessHandle
  /// Login-shell environment for install commands; defaults to process.env.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  /// Staged clone; defaults to a shallow `git clone`.
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
  /// Persistent state root (`<server-data>/plugin-data`). Transactional
  /// updates snapshot the plugin's directory here before starting a candidate.
  readonly pluginDataRoot: string
  /// Starts the installed candidate and resolves only after readiness passes.
  readonly verifyInstalled: (pluginId: string) => Promise<void>
  /// When present, install-command output streams into an attachable
  /// external terminal (sessionId `plugin-install:{id}`).
  readonly registerExternalTerminal?: RegisterPluginTerminal | undefined
  /// Stops the plugin's process before its directory is replaced or removed.
  readonly stop: (pluginId: string) => void
}

export interface PluginInstaller {
  readonly discoverRemote: (
    request: DiscoverRemotePluginRequest
  ) => Promise<DiscoverRemotePluginResult>
  /// Installs (or updates a managed install of) the plugin the source
  /// provides and resolves its manifest.
  readonly importRemote: (request: ImportRemotePluginRequest) => Promise<PluginManifest>
  /// Fetches, validates, and runs setup for an exact update candidate without
  /// stopping or changing the installed plugin.
  readonly prepareUpdate: (request: PreparePluginUpdateRequest) => Promise<PreparedPluginUpdate>
  /// Applies only the bytes represented by a prepared handle.
  readonly applyPreparedUpdate: (prepared: PreparedPluginUpdate) => Promise<PluginManifest>
  readonly discardPreparedUpdate: (prepared: PreparedPluginUpdate) => Promise<void>
  /// Repairs or finishes any transaction journal left by a process crash.
  readonly recover: () => Promise<void>
  /// Managed-marker-gated uninstall; linked plugins are never deleted.
  readonly remove: (pluginId: string) => Promise<void>
  /// Dev mode: symlink a local plugin directory into the plugins root.
  readonly link: (request: LinkPluginRequest) => Promise<PluginManifest>
}

/// Same containment rule as skills-store's isPathSafe: the candidate must be
/// the root itself or live strictly under it.
const isPathSafe = (root: string, candidate: string): boolean => {
  const normalizedRoot = normalize(resolve(root))
  const normalizedCandidate = normalize(resolve(candidate))
  return (
    normalizedCandidate.startsWith(normalizedRoot + sep) || normalizedCandidate === normalizedRoot
  )
}

const receiptSource = (source: ParsedPluginSource): PluginInstallSourceReceipt => ({
  kind: source.repo !== undefined ? "github" : source.local === true ? "local" : "git",
  tracking: source.repo !== undefined && source.ref === undefined ? "registry" : "pinned",
  url: source.url,
  ...(source.repo === undefined ? {} : { repo: source.repo }),
  ...(source.ref === undefined ? {} : { requestedRef: source.ref }),
  ...(source.subpath === undefined ? {} : { subpath: source.subpath })
})

export const makePluginInstaller = (deps: PluginInstallerDeps): PluginInstaller => {
  const clone = deps.clone ?? clonePluginSource
  const spawnShell = deps.spawnShell ?? defaultSpawnShell
  const spawnArgv = deps.spawnArgv ?? defaultSpawnArgv
  const resolveEnv = deps.resolveEnv ?? (() => Promise.resolve(process.env))
  const platform = deps.platform ?? process.platform
  const receiptNow = deps.receiptNow ?? (() => new Date())
  const transactions = makePluginTransactionEngine({
    pluginDataRoot: deps.pluginDataRoot,
    pluginsRoot: deps.pluginsRoot,
    stop: deps.stop,
    verifyInstalled: deps.verifyInstalled
  })
  const updatePlansRoot = join(deps.pluginsRoot, ".codevisor-update-plans")

  /// Stage a source into a fresh temp clone and read its manifest. The
  /// verbatim install/run commands surfaced from here are exactly what the
  /// consent UI shows — never derived, never normalized.
  const stage = async (
    source: string,
    sourceOverride?: PluginInstallSourceReceipt
  ): Promise<StagedPlugin> => {
    const parsed = parsePluginSource(source)
    const env = await resolveEnv()
    await assertGitAvailable(env, deps.findExecutable)
    const staging = await mkdtemp(join(tmpdir(), "codevisor-plugin-install-"))
    const cleanup = async (): Promise<void> => {
      await rm(staging, { force: true, recursive: true })
    }
    let resolvedCommit: string
    try {
      try {
        const cloned = await clone(parsed.url, parsed.ref, staging, env)
        resolvedCommit = cloned.resolvedCommit
      } catch (cause) {
        throw new PluginsError(
          "invalid",
          `Couldn't fetch ${parsed.url}${parsed.ref === undefined ? "" : ` (${parsed.ref})`}: ${
            cause instanceof Error ? cause.message : String(cause)
          }`
        )
      }
      let root = staging
      if (parsed.subpath !== undefined) {
        const candidate = join(staging, parsed.subpath)
        if (!isPathSafe(staging, candidate)) {
          throw new PluginsError("invalid", `Invalid source path: ${parsed.subpath}`)
        }
        root = candidate
      }
      let raw: string
      try {
        raw = await readFile(join(root, PLUGIN_MANIFEST_FILENAME), "utf8")
      } catch {
        throw new PluginsError("invalid", `No ${PLUGIN_MANIFEST_FILENAME} found in ${source}`)
      }
      const manifest = parsePluginManifest(raw)
      // Anti-impersonation: a repo installed as `owner/repo` (or a
      // github.com URL) may only provide plugins in the `owner.` namespace,
      // so a fork cannot publish itself under someone else's plugin id.
      // Local-path sources are dev installs with no owner to validate.
      if (
        parsed.local !== true &&
        parsed.owner !== undefined &&
        !manifest.id.startsWith(`${parsed.owner.toLowerCase()}.`)
      ) {
        throw new PluginsError(
          "invalid",
          `Plugin id ${manifest.id} does not match the source owner — plugins from ${parsed.owner} must use ids starting with "${parsed.owner.toLowerCase()}."`
        )
      }
      return {
        cleanup,
        env,
        manifest,
        manifestRaw: raw,
        resolvedCommit,
        root,
        source: sourceOverride ?? receiptSource(parsed)
      }
    } catch (cause) {
      await cleanup()
      throw cause
    }
  }

  const installedWithId = (pluginId: string): InstalledPlugin | undefined =>
    scanPlugins(deps.pluginsRoot).plugins.find((candidate) => candidate.id === pluginId)

  /// The plugin id doubles as the managed directory name. The manifest id
  /// pattern already forbids separators; this guard keeps the invariant
  /// load-bearing rather than assumed.
  const managedDirectory = (pluginId: string): string => {
    const destination = join(deps.pluginsRoot, pluginId)
    /* v8 ignore next 3 -- unreachable: parsePluginManifest rejects ids with separators. */
    if (basename(destination) !== pluginId || !isPathSafe(deps.pluginsRoot, destination)) {
      throw new PluginsError("invalid", `Invalid plugin directory name: ${pluginId}`)
    }
    return destination
  }

  /// Runs one setup command in the plugin directory, streaming output through
  /// the observability terminal. Success is a zero exit code from the spawner.
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
    /* v8 ignore next 3 -- the manifest and plan-id patterns make this unreachable. */
    if (!isPathSafe(updatePlansRoot, directory)) {
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

  return {
    discoverRemote: async (request) => {
      const staged = await stage(request.source)
      try {
        const { manifest } = staged
        const runCommand = pluginRunCommand(manifest)
        const setupCommands = pluginSetupCommands(manifest, platform)
        return {
          alreadyInstalled: installedWithId(manifest.id) !== undefined,
          id: manifest.id,
          name: manifest.name,
          panes: manifest.panes,
          runCommand: displayPluginCommand(runCommand),
          version: manifest.version,
          ...(manifest.description === undefined ? {} : { description: manifest.description }),
          ...(manifest.iconPath === undefined ? {} : { iconPath: manifest.iconPath }),
          ...(setupCommands.length === 0
            ? {}
            : { installCommand: setupCommands.map(displayPluginCommand).join(" && ") }),
          ...(manifest.protocolVersion === 1 || manifest.setup === undefined
            ? {}
            : { setupCommands: manifest.setup }),
          ...(manifest.protocolVersion === 1 || manifest.minCodevisorVersion === undefined
            ? {}
            : { minCodevisorVersion: manifest.minCodevisorVersion }),
          ...(manifest.protocolVersion === 1 || manifest.requirements === undefined
            ? {}
            : { requirements: manifest.requirements }),
          ...(manifest.tools === undefined ? {} : { tools: manifest.tools })
        }
      } finally {
        await staged.cleanup()
      }
    },
    importRemote: async (request) => {
      const staged = await stage(request.source)
      try {
        await importStaged(staged)
        return staged.manifest
      } finally {
        await staged.cleanup()
      }
    },
    prepareUpdate: async (request) => {
      const staged = await stage(request.source, request.sourceReceipt)
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
      // Plans are process-local capabilities. They cannot be applied after a
      // restart, so abandoned staged bytes are removed during recovery.
      await rm(updatePlansRoot, { force: true, recursive: true })
    },
    link: async (request) => {
      if (!isAbsolute(request.path)) {
        throw new PluginsError("invalid", `Plugin link path must be absolute: ${request.path}`)
      }
      const target = resolve(request.path)
      let targetStats
      try {
        targetStats = await stat(target)
      } catch {
        throw new PluginsError("invalid", `Not a directory: ${request.path}`)
      }
      if (!targetStats.isDirectory()) {
        throw new PluginsError("invalid", `Not a directory: ${request.path}`)
      }
      let raw: string
      try {
        raw = await readFile(join(target, PLUGIN_MANIFEST_FILENAME), "utf8")
      } catch {
        throw new PluginsError("invalid", `No ${PLUGIN_MANIFEST_FILENAME} found in ${request.path}`)
      }
      const manifest = parsePluginManifest(raw)
      return transactions.withLock(manifest.id, async () => {
        await transactions.recoverPlugin(manifest.id)
        if (installedWithId(manifest.id) !== undefined) {
          throw new PluginsError("conflict", `Plugin ${manifest.id} is already installed`)
        }
        const destination = managedDirectory(manifest.id)
        try {
          await lstat(destination)
          throw new PluginsError(
            "conflict",
            `${destination} already exists — remove it before linking`
          )
        } catch (cause) {
          if (cause instanceof PluginsError) {
            throw cause
          }
          // ENOENT: the link path is free.
        }
        await mkdir(deps.pluginsRoot, { recursive: true })
        await symlink(target, destination)
        return manifest
      })
    },
    remove: async (pluginId) => {
      await transactions.withLock(pluginId, async () => {
        await transactions.recoverPlugin(pluginId)
        const plugin = installedWithId(pluginId)
        if (plugin === undefined) {
          throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
        }
        // The iron rule (same as skills): uninstall deletes only directories
        // Codevisor provably created. Links are the developer's — even one
        // whose target happens to contain a marker.
        const stats = await lstat(plugin.path)
        if (stats.isSymbolicLink() || plugin.source !== "managed") {
          throw new PluginsError(
            "invalid",
            `Plugin ${pluginId} is linked, not managed — remove the link from ${deps.pluginsRoot} yourself`
          )
        }
        deps.stop(pluginId)
        await rm(plugin.path, { force: true, recursive: true })
      })
    }
  }
}
