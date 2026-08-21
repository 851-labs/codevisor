import type {
  DiscoverRemotePluginRequest,
  DiscoverRemotePluginResult,
  ImportRemotePluginRequest,
  LinkPluginRequest,
  PluginManifest
} from "@codevisor/api"
import { cp, lstat, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, isAbsolute, join, normalize, resolve, sep } from "node:path"
import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import { clonePluginSource, parsePluginSource } from "./plugin-source.js"
import {
  MANAGED_PLUGIN_MARKER,
  MANAGED_PLUGIN_MARKER_CONTENT,
  scanPlugins,
  type InstalledPlugin
} from "./plugin-store.js"
import type {
  PluginProcessHandle,
  PluginSpawnOptions,
  RegisterPluginTerminal
} from "./plugin-supervisor.js"
import { defaultSpawnShell } from "./plugin-supervisor.js"
import { PluginsError } from "./plugins-error.js"

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
  /// Login-shell environment for install commands; defaults to process.env.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  /// Staged clone; defaults to a shallow `git clone`.
  readonly clone?: (url: string, ref: string | undefined, destination: string) => Promise<void>
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

interface StagedPlugin {
  readonly manifest: PluginManifest
  readonly root: string
  readonly cleanup: () => Promise<void>
}

export const makePluginInstaller = (deps: PluginInstallerDeps): PluginInstaller => {
  const clone = deps.clone ?? clonePluginSource
  const spawnShell = deps.spawnShell ?? defaultSpawnShell
  const resolveEnv = deps.resolveEnv ?? (() => Promise.resolve(process.env))

  /// Stage a source into a fresh temp clone and read its manifest. The
  /// verbatim install/run commands surfaced from here are exactly what the
  /// consent UI shows — never derived, never normalized.
  const stage = async (source: string): Promise<StagedPlugin> => {
    const parsed = parsePluginSource(source)
    const staging = await mkdtemp(join(tmpdir(), "codevisor-plugin-install-"))
    const cleanup = async (): Promise<void> => {
      await rm(staging, { force: true, recursive: true })
    }
    try {
      try {
        await clone(parsed.url, parsed.ref, staging)
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
      return { cleanup, manifest, root }
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

  /// Runs the manifest install command in the plugin directory, streaming
  /// output through the observability terminal. Success is a zero exit code
  /// from the spawner.
  const runInstallCommand = (
    manifest: PluginManifest,
    directory: string,
    env: NodeJS.ProcessEnv
  ): Promise<{ readonly ok: boolean; readonly message: string }> =>
    new Promise((resolvePromise) => {
      /* v8 ignore next -- callers gate on manifest.install; the ?? arm is a type guard. */
      const command = manifest.install?.command ?? ""
      const child = spawnShell(command, {
        cwd: directory,
        env: { ...env, CODEVISOR_PLUGIN_ID: manifest.id }
      })
      const terminal = deps.registerExternalTerminal?.(
        { normalizeNewlines: true, sessionId: `plugin-install:${manifest.id}` },
        { kill: () => child.kill(), resize: () => undefined, write: () => undefined }
      )
      terminal?.output(`$ ${command}\r\n`)
      child.onOutput?.((data) => terminal?.output(data))
      child.onExit((message, exitCode) => {
        terminal?.exit(exitCode ?? undefined)
        resolvePromise({ message, ok: exitCode === 0 })
      })
    })

  const importStaged = async (staged: StagedPlugin): Promise<void> => {
    const destination = managedDirectory(staged.manifest.id)
    const existing = installedWithId(staged.manifest.id)
    if (existing !== undefined && resolve(existing.path) !== resolve(destination)) {
      throw new PluginsError(
        "conflict",
        `Plugin ${staged.manifest.id} is already provided by ${existing.directoryName} (${existing.source})`
      )
    }
    let destinationStats
    try {
      destinationStats = await lstat(destination)
    } catch {
      destinationStats = undefined
    }
    if (destinationStats !== undefined) {
      // Only directories Codevisor provably created (a real directory —
      // lstat, so links never qualify — carrying the managed marker) may be
      // replaced; anything else — a linked dev plugin or a foreign
      // directory — is the user's and stays untouched.
      const managed =
        destinationStats.isDirectory() &&
        (await lstat(join(destination, MANAGED_PLUGIN_MARKER)).then(
          () => true,
          () => false
        ))
      if (!managed) {
        throw new PluginsError(
          "conflict",
          `${destination} already exists and was not installed by Codevisor — remove or link it instead`
        )
      }
      deps.stop(staged.manifest.id)
      await rm(destination, { force: true, recursive: true })
    }
    await mkdir(deps.pluginsRoot, { recursive: true })
    // The staged clone's .git directory is history, not plugin content.
    await cp(staged.root, destination, {
      filter: (source) => basename(source) !== ".git",
      recursive: true
    })
    await writeFile(join(destination, MANAGED_PLUGIN_MARKER), MANAGED_PLUGIN_MARKER_CONTENT, "utf8")
    if (staged.manifest.install !== undefined) {
      const outcome = await runInstallCommand(staged.manifest, destination, await resolveEnv())
      if (!outcome.ok) {
        // A half-installed plugin must not linger as a managed install.
        await rm(destination, { force: true, recursive: true })
        throw new PluginsError(
          "invalid",
          `Plugin ${staged.manifest.id} install command failed: ${outcome.message}`
        )
      }
    }
  }

  return {
    discoverRemote: async (request) => {
      const staged = await stage(request.source)
      try {
        const { manifest } = staged
        return {
          alreadyInstalled: installedWithId(manifest.id) !== undefined,
          id: manifest.id,
          name: manifest.name,
          panes: manifest.panes,
          runCommand: manifest.run.command,
          version: manifest.version,
          ...(manifest.description === undefined ? {} : { description: manifest.description }),
          ...(manifest.iconPath === undefined ? {} : { iconPath: manifest.iconPath }),
          ...(manifest.install === undefined ? {} : { installCommand: manifest.install.command }),
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
    },
    remove: async (pluginId) => {
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
    }
  }
}
