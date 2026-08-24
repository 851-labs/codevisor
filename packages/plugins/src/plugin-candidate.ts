import { cp, lstat, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { basename, dirname, join, resolve } from "node:path"
import type { PluginManifest } from "@codevisor/api"
import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import { readPluginInstallReceipt, writePluginInstallReceipt } from "./plugin-receipt.js"
import { assertPluginRequirements, type FindExecutable } from "./plugin-requirements.js"
import {
  MANAGED_PLUGIN_MARKER,
  MANAGED_PLUGIN_MARKER_CONTENT,
  type InstalledPlugin
} from "./plugin-store.js"
import type { PreparedCandidateContext, StagedPlugin } from "./plugin-install-types.js"
import { PluginsError } from "./plugins-error.js"

export interface PluginCandidatePreparerDeps {
  readonly pluginsRoot: string
  readonly platform: string
  readonly codevisorVersion?: string
  readonly findExecutable?: FindExecutable
  readonly receiptNow: () => Date
  readonly installedWithId: (pluginId: string) => InstalledPlugin | undefined
  readonly managedDirectory: (pluginId: string) => string
  readonly runSetup: (
    manifest: PluginManifest,
    directory: string,
    env: NodeJS.ProcessEnv,
    previousVersion: string | undefined
  ) => Promise<void>
}

export interface PluginCandidatePreparer {
  readonly prepare: (
    staged: StagedPlugin,
    candidateDirectory: string,
    requireExisting: boolean
  ) => Promise<PreparedCandidateContext>
}

export const makePluginCandidatePreparer = (
  deps: PluginCandidatePreparerDeps
): PluginCandidatePreparer => ({
  prepare: async (staged, candidateDirectory, requireExisting) => {
    const destination = deps.managedDirectory(staged.manifest.id)
    const existing = deps.installedWithId(staged.manifest.id)
    if (existing !== undefined && resolve(existing.path) !== resolve(destination)) {
      throw new PluginsError(
        "conflict",
        `Plugin ${staged.manifest.id} is already provided by ${existing.directoryName} (${existing.source})`
      )
    }
    if (requireExisting && existing === undefined) {
      throw new PluginsError("notFound", `Plugin not installed: ${staged.manifest.id}`)
    }
    await assertPluginRequirements({
      env: staged.env,
      manifest: staged.manifest,
      platform: deps.platform,
      ...(deps.codevisorVersion === undefined ? {} : { codevisorVersion: deps.codevisorVersion }),
      ...(deps.findExecutable === undefined ? {} : { findExecutable: deps.findExecutable })
    })
    const previousReceipt = readPluginInstallReceipt(destination)
    let destinationStats
    try {
      destinationStats = await lstat(destination)
    } catch {
      destinationStats = undefined
    }
    if (destinationStats !== undefined) {
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
    }

    await mkdir(dirname(candidateDirectory), { recursive: true })
    await rm(candidateDirectory, { force: true, recursive: true })
    await cp(staged.root, candidateDirectory, {
      filter: (source) => basename(source) !== ".git",
      recursive: true
    })
    await writeFile(
      join(candidateDirectory, MANAGED_PLUGIN_MARKER),
      MANAGED_PLUGIN_MARKER_CONTENT,
      "utf8"
    )
    await deps.runSetup(staged.manifest, candidateDirectory, staged.env, existing?.manifest.version)
    const preparedRaw = await readFile(join(candidateDirectory, PLUGIN_MANIFEST_FILENAME), "utf8")
    if (preparedRaw !== staged.manifestRaw) {
      throw new PluginsError(
        "invalid",
        `Plugin ${staged.manifest.id} setup changed ${PLUGIN_MANIFEST_FILENAME}; setup must leave the reviewed manifest unchanged`
      )
    }
    parsePluginManifest(preparedRaw)
    const timestamp = deps.receiptNow().toISOString()
    await writePluginInstallReceipt(candidateDirectory, {
      installedAt: previousReceipt?.installedAt ?? timestamp,
      installedVersion: staged.manifest.version,
      pluginId: staged.manifest.id,
      resolvedCommit: staged.resolvedCommit,
      schemaVersion: 1,
      source: staged.source,
      updatedAt: timestamp
    })
    return {
      hadExisting: destinationStats !== undefined,
      ...(existing === undefined ? {} : { previousManifest: existing.manifest }),
      ...(previousReceipt === undefined ? {} : { previousReceipt })
    }
  }
})
