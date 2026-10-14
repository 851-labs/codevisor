import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, normalize, resolve, sep } from "node:path"

import type { PluginManifest } from "@codevisor/api"

import type { StagedPlugin } from "./plugin-install-types.js"
import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import type { PluginInstallSourceReceipt } from "./plugin-receipt.js"
import { assertGitAvailable, type FindExecutable } from "./plugin-requirements.js"
import {
  parsePluginSource,
  type ClonePluginSourceResult,
  type ParsedPluginSource
} from "./plugin-source.js"
import { PluginsError } from "./plugins-error.js"

interface PluginStagingDeps {
  readonly clone: (
    url: string,
    ref: string | undefined,
    destination: string,
    env: NodeJS.ProcessEnv
  ) => Promise<ClonePluginSourceResult>
  readonly resolveEnv: () => Promise<NodeJS.ProcessEnv>
  readonly findExecutable?: FindExecutable | undefined
}

export const isPluginPathSafe = (root: string, candidate: string): boolean => {
  const normalizedRoot = normalize(resolve(root))
  const normalizedCandidate = normalize(resolve(candidate))
  return (
    normalizedCandidate.startsWith(normalizedRoot + sep) || normalizedCandidate === normalizedRoot
  )
}

const sourceDirectory = (staging: string, source: ParsedPluginSource): string => {
  if (source.subpath === undefined) return staging
  const candidate = join(staging, source.subpath)
  if (!isPluginPathSafe(staging, candidate)) {
    throw new PluginsError("invalid", `Invalid source path: ${source.subpath}`)
  }
  return candidate
}

const assertSourceOwner = (parsed: ParsedPluginSource, manifest: PluginManifest): void => {
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
}

const receiptSource = (source: ParsedPluginSource): PluginInstallSourceReceipt => ({
  kind: source.repo !== undefined ? "github" : source.local === true ? "local" : "git",
  tracking: source.repo !== undefined && source.ref === undefined ? "registry" : "pinned",
  url: source.url,
  ...(source.repo === undefined ? {} : { repo: source.repo }),
  ...(source.ref === undefined ? {} : { requestedRef: source.ref }),
  ...(source.subpath === undefined ? {} : { subpath: source.subpath })
})

const fetchSource = async (
  parsed: ParsedPluginSource,
  staging: string,
  env: NodeJS.ProcessEnv,
  clone: PluginStagingDeps["clone"]
): Promise<ClonePluginSourceResult> => {
  try {
    return await clone(parsed.url, parsed.ref, staging, env)
  } catch (cause) {
    throw new PluginsError(
      "invalid",
      `Couldn't fetch ${parsed.url}${parsed.ref === undefined ? "" : ` (${parsed.ref})`}: ${
        cause instanceof Error ? cause.message : String(cause)
      }`
    )
  }
}

const readSourceManifest = async (root: string, source: string): Promise<string> => {
  try {
    return await readFile(join(root, PLUGIN_MANIFEST_FILENAME), "utf8")
  } catch {
    throw new PluginsError("invalid", `No ${PLUGIN_MANIFEST_FILENAME} found in ${source}`)
  }
}

export const stagePluginSource = async (
  source: string,
  deps: PluginStagingDeps,
  sourceOverride?: PluginInstallSourceReceipt
): Promise<StagedPlugin> => {
  const { clone, resolveEnv } = deps
  const parsed = parsePluginSource(source)
  const env = await resolveEnv()
  await assertGitAvailable(env, deps.findExecutable)
  const staging = await mkdtemp(join(tmpdir(), "codevisor-plugin-install-"))
  const cleanup = async (): Promise<void> => {
    await rm(staging, { force: true, recursive: true })
  }
  try {
    const { resolvedCommit } = await fetchSource(parsed, staging, env, clone)
    const root = sourceDirectory(staging, parsed)
    const raw = await readSourceManifest(root, source)
    const manifest = parsePluginManifest(raw)
    assertSourceOwner(parsed, manifest)
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
