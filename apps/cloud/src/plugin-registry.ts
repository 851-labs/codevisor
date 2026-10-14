import {
  decode,
  isSemanticVersion,
  isSupportedPluginProtocolVersion,
  PluginManifest,
  type PluginPaneDescriptor,
  type PluginRequirements,
  type PluginToolDescriptor
} from "@codevisor/api"

import type { CloudEnv } from "./env.js"

export const PLUGIN_TOPIC = "codevisor-plugin"

export const PLUGIN_MANIFEST_FILENAME = "codevisor-plugin.json"

export const PLUGIN_INDEX_KEY = "index"
const ENTRY_KEY_PREFIX = "entry:"
export const pluginEntryKey = (id: string): string => `${ENTRY_KEY_PREFIX}${id}`

export interface PluginIndexEntry {
  url?: string
  ageRating?: number
  id: string
  name: string
  version: string
  protocolVersion: number
  description?: string
  iconPath?: string
  panes: readonly PluginPaneDescriptor[]
  tools?: readonly PluginToolDescriptor[]
  repo: string
  commit: string
  minCodevisorVersion?: string
  requirements?: PluginRequirements
  platforms?: readonly string[]
  ownerAvatarUrl?: string
  stars: number
  pushedAt: string
  verified?: boolean
}

export interface PluginIndexRejection {
  repo: string
  reason: string
}

export interface PluginIndex {
  generatedAt: string
  entries: PluginIndexEntry[]
  rejected: PluginIndexRejection[]
}

export interface PluginRefreshSummary {
  generatedAt: string
  indexed: number
  rejected: number
}

type FetchLike = NonNullable<CloudEnv["GITHUB_FETCH"]>

interface GitHubSearchRepo {
  full_name: string
  default_branch: string
  stargazers_count: number
  pushed_at: string
  owner: { login: string; avatar_url?: string } | null
}

const githubHeaders = (token: string | undefined): Record<string, string> => ({
  accept: "application/vnd.github+json",
  "user-agent": "codevisor-cloud-plugin-indexer",
  "x-github-api-version": "2022-11-28",
  ...(token !== undefined ? { authorization: `Bearer ${token}` } : {})
})

const SEARCH_PAGE_SIZE = 100
const MAX_SEARCH_PAGES = 10

const searchTaggedRepos = async (
  fetchImpl: FetchLike,
  token: string | undefined
): Promise<GitHubSearchRepo[]> => {
  const repos: GitHubSearchRepo[] = []
  for (let page = 1; page <= MAX_SEARCH_PAGES; page++) {
    const query = encodeURIComponent(`topic:${PLUGIN_TOPIC}`)
    const url = `https://api.github.com/search/repositories?q=${query}&per_page=${SEARCH_PAGE_SIZE}&page=${page}`
    const response = await fetchImpl(url, { headers: githubHeaders(token) })
    if (!response.ok) throw new Error(`GitHub search failed with status ${response.status}`)
    const body = (await response.json()) as { items?: GitHubSearchRepo[] }
    const items = body.items ?? []
    repos.push(...items)
    if (items.length < SEARCH_PAGE_SIZE) break
  }
  return repos
}

const resolveDefaultBranchCommit = async (
  fetchImpl: FetchLike,
  token: string | undefined,
  repo: GitHubSearchRepo
): Promise<string> => {
  const url = `https://api.github.com/repos/${repo.full_name}/commits/${encodeURIComponent(repo.default_branch)}`
  const response = await fetchImpl(url, { headers: githubHeaders(token) })
  if (!response.ok) {
    throw new Error(`commit resolution failed with status ${response.status}`)
  }
  const body = (await response.json()) as { sha?: unknown }
  if (typeof body.sha !== "string" || !/^[0-9a-f]{40}$/i.test(body.sha)) {
    throw new Error("commit resolution returned an invalid SHA")
  }
  return body.sha
}

const manifestUrl = (repo: GitHubSearchRepo, commit: string): string =>
  `https://raw.githubusercontent.com/${repo.full_name}/${commit}/${PLUGIN_MANIFEST_FILENAME}`

const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/

type ManifestValidation = { ok: true; manifest: PluginManifest } | { ok: false; reason: string }

const unsupportedIndexProtocol = (json: unknown): ManifestValidation | undefined => {
  const protocolVersion =
    typeof json === "object" && json !== null && "protocolVersion" in json
      ? (json as { protocolVersion?: unknown }).protocolVersion
      : undefined
  if (typeof protocolVersion === "number" && !isSupportedPluginProtocolVersion(protocolVersion)) {
    return {
      ok: false,
      reason: `unsupported plugin protocolVersion ${protocolVersion} (this index supports 1 and 2)`
    }
  }
  return undefined
}

const invalidIndexedVersion = (manifest: PluginManifest): ManifestValidation | undefined => {
  if (
    manifest.protocolVersion === 2 &&
    (!isSemanticVersion(manifest.version) ||
      (manifest.minCodevisorVersion !== undefined &&
        !isSemanticVersion(manifest.minCodevisorVersion)))
  ) {
    return { ok: false, reason: "protocol v2 version fields must use strict SemVer" }
  }
  return undefined
}

const validateIndexedIdentity = (
  manifest: PluginManifest,
  repoOwner: string
): ManifestValidation => {
  if (!PLUGIN_ID_PATTERN.test(manifest.id)) {
    return {
      ok: false,
      reason: `plugin id must be lowercase "owner.name" (letters, digits, hyphens): ${manifest.id}`
    }
  }
  const namespace = manifest.id.split(".")[0]
  if (namespace !== repoOwner.toLowerCase()) {
    return {
      ok: false,
      reason: `plugin id "${manifest.id}" must be namespaced under the repo owner ("${repoOwner.toLowerCase()}.…")`
    }
  }
  return { ok: true, manifest }
}

const decodeIndexedManifest = (json: unknown, repoOwner: string): ManifestValidation => {
  let manifest: PluginManifest
  try {
    manifest = decode(PluginManifest)(json)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { ok: false, reason: `invalid plugin manifest: ${message}` }
  }
  const invalidVersion = invalidIndexedVersion(manifest)
  if (invalidVersion !== undefined) return invalidVersion
  return validateIndexedIdentity(manifest, repoOwner)
}

export const validateManifestForIndex = (raw: string, repoOwner: string): ManifestValidation => {
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    return { ok: false, reason: `${PLUGIN_MANIFEST_FILENAME} is not valid JSON` }
  }
  const unsupportedProtocol = unsupportedIndexProtocol(json)
  if (unsupportedProtocol !== undefined) return unsupportedProtocol
  return decodeIndexedManifest(json, repoOwner)
}

const toEntry = (
  manifest: PluginManifest,
  repo: GitHubSearchRepo,
  commit: string
): PluginIndexEntry => ({
  commit,
  id: manifest.id,
  name: manifest.name,
  url: `https://www.codevisor.dev/plugins/${manifest.id}`,
  ...(manifest.ageRating === undefined ? {} : { ageRating: manifest.ageRating }),
  version: manifest.version,
  protocolVersion: manifest.protocolVersion,
  ...(manifest.description !== undefined ? { description: manifest.description } : {}),
  ...(manifest.iconPath !== undefined ? { iconPath: manifest.iconPath } : {}),
  panes: manifest.panes,
  ...(manifest.tools !== undefined ? { tools: manifest.tools } : {}),
  ...(manifest.platforms !== undefined ? { platforms: manifest.platforms } : {}),
  ...(manifest.protocolVersion === 1 || manifest.minCodevisorVersion === undefined
    ? {}
    : { minCodevisorVersion: manifest.minCodevisorVersion }),
  ...(manifest.protocolVersion === 1 || manifest.requirements === undefined
    ? {}
    : { requirements: manifest.requirements }),
  repo: repo.full_name,
  ...(repo.owner?.avatar_url !== undefined ? { ownerAvatarUrl: repo.owner.avatar_url } : {}),
  stars: repo.stargazers_count,
  pushedAt: repo.pushed_at
})

const writeIndex = async (kv: KVNamespace, index: PluginIndex): Promise<void> => {
  const alive = new Set(index.entries.map((entry) => pluginEntryKey(entry.id)))
  await kv.put(PLUGIN_INDEX_KEY, JSON.stringify(index))
  for (const entry of index.entries) {
    await kv.put(pluginEntryKey(entry.id), JSON.stringify(entry))
  }
  let cursor: string | undefined
  do {
    const page = await kv.list({
      prefix: ENTRY_KEY_PREFIX,
      ...(cursor !== undefined ? { cursor } : {})
    })
    for (const key of page.keys) {
      if (!alive.has(key.name)) await kv.delete(key.name)
    }
    cursor = page.list_complete ? undefined : page.cursor
  } while (cursor !== undefined)
}

export const refreshPluginIndex = async (env: CloudEnv): Promise<PluginRefreshSummary> => {
  const fetchImpl: FetchLike = env.GITHUB_FETCH ?? globalThis.fetch
  const repos = await searchTaggedRepos(fetchImpl, env.GITHUB_TOKEN)
  const entries: PluginIndexEntry[] = []
  const rejected: PluginIndexRejection[] = []
  const claimed = new Map<string, string>()
  for (const repo of repos) {
    const owner = repo.owner?.login
    if (owner === undefined) {
      rejected.push({ repo: repo.full_name, reason: "repository has no owner" })
      continue
    }
    let commit: string
    try {
      commit = await resolveDefaultBranchCommit(fetchImpl, env.GITHUB_TOKEN, repo)
    } catch (cause) {
      rejected.push({
        repo: repo.full_name,
        reason: cause instanceof Error ? cause.message : String(cause)
      })
      continue
    }
    const response = await fetchImpl(manifestUrl(repo, commit), {
      headers: { "user-agent": "codevisor-cloud-plugin-indexer" }
    })
    if (response.status === 404) {
      rejected.push({
        repo: repo.full_name,
        reason: `${PLUGIN_MANIFEST_FILENAME} not found at resolved commit ${commit}`
      })
      continue
    }
    if (!response.ok) {
      rejected.push({
        repo: repo.full_name,
        reason: `manifest fetch failed with status ${response.status}`
      })
      continue
    }
    const validated = validateManifestForIndex(await response.text(), owner)
    if (!validated.ok) {
      rejected.push({ repo: repo.full_name, reason: validated.reason })
      continue
    }
    const previous = claimed.get(validated.manifest.id)
    if (previous !== undefined) {
      rejected.push({
        repo: repo.full_name,
        reason: `plugin id "${validated.manifest.id}" already indexed from ${previous}`
      })
      continue
    }
    claimed.set(validated.manifest.id, repo.full_name)
    entries.push(toEntry(validated.manifest, repo, commit))
  }
  entries.sort((a, b) => b.stars - a.stars || a.id.localeCompare(b.id))
  const index: PluginIndex = { generatedAt: new Date().toISOString(), entries, rejected }
  await writeIndex(env.PLUGIN_INDEX, index)
  return { generatedAt: index.generatedAt, indexed: entries.length, rejected: rejected.length }
}
