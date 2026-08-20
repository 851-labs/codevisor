// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  decode,
  PLUGINS_PROTOCOL_VERSION,
  PluginManifest,
  type PluginPaneDescriptor,
  type PluginToolDescriptor
} from "@codevisor/api"
import type { CloudEnv } from "./env.js"

/// GitHub topic that marks a public repository as a Codevisor plugin. Tagging
/// a repo publishes it to the index on the next poll; untagging drops it.
export const PLUGIN_TOPIC = "codevisor-plugin"

export const PLUGIN_MANIFEST_FILENAME = "codevisor-plugin.json"

/// KV layout: the whole index under one key (served as /plugins/index.json
/// verbatim) plus one key per entry so /plugins/:id.json is a single read.
export const PLUGIN_INDEX_KEY = "index"
const ENTRY_KEY_PREFIX = "entry:"
export const pluginEntryKey = (id: string): string => `${ENTRY_KEY_PREFIX}${id}`

// -- Wire shapes ---------------------------------------------------------------

/// One indexed plugin: manifest metadata the app can render without running
/// anything, plus the GitHub facts (repo, stars, push time) that anchor it to
/// a real owner. This is the Phase 1 shape; Phase 2 mirrors it into
/// packages/api as the server-passthrough wire type.
export interface PluginIndexEntry {
  id: string
  name: string
  version: string
  description?: string
  panes: readonly PluginPaneDescriptor[]
  tools?: readonly PluginToolDescriptor[]
  /// GitHub "owner/name" — the directory always shows the real repo owner.
  repo: string
  stars: number
  pushedAt: string
  /// Curation groundwork: reserved for first-party verification of an entry.
  /// The indexer never sets it yet, so it is always absent today.
  verified?: boolean
}

/// Why a tagged repo was left out — published alongside the index so plugin
/// authors can see (and fix) exactly what disqualified them.
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

// -- GitHub fetch pipeline -----------------------------------------------------

type FetchLike = NonNullable<CloudEnv["GITHUB_FETCH"]>

/// The subset of a GitHub search item the indexer consumes.
interface GitHubSearchRepo {
  full_name: string
  default_branch: string
  stargazers_count: number
  pushed_at: string
  owner: { login: string } | null
}

const githubHeaders = (token: string | undefined): Record<string, string> => ({
  accept: "application/vnd.github+json",
  "user-agent": "codevisor-cloud-plugin-indexer",
  "x-github-api-version": "2022-11-28",
  ...(token !== undefined ? { authorization: `Bearer ${token}` } : {})
})

const SEARCH_PAGE_SIZE = 100
/// GitHub's search API serves at most 1000 results (10 pages of 100).
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

/// Raw-content URL for the manifest on the repo's default branch — one
/// unauthenticated CDN fetch per repo instead of a contents-API call.
const manifestUrl = (repo: GitHubSearchRepo): string =>
  `https://raw.githubusercontent.com/${repo.full_name}/${repo.default_branch}/${PLUGIN_MANIFEST_FILENAME}`

// -- Manifest validation ---------------------------------------------------------

/// Mirrors packages/plugins/src/plugin-manifest.ts (PLUGIN_ID_PATTERN) — the
/// id grammar is part of the plugin protocol.
const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/

type ManifestValidation = { ok: true; manifest: PluginManifest } | { ok: false; reason: string }

/// Structural validation for indexing. Reuses the PluginManifest Effect
/// Schema from @codevisor/api; the full install-time ruleset lives in
/// packages/plugins/src/plugin-manifest.ts (parsePluginManifest) and still
/// runs on the user's machine before anything executes — the index only needs
/// enough to publish honest metadata under the right owner.
export const validateManifestForIndex = (raw: string, repoOwner: string): ManifestValidation => {
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    return { ok: false, reason: `${PLUGIN_MANIFEST_FILENAME} is not valid JSON` }
  }
  let manifest: PluginManifest
  try {
    manifest = decode(PluginManifest)(json)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { ok: false, reason: `invalid plugin manifest: ${message}` }
  }
  if (manifest.protocolVersion !== PLUGINS_PROTOCOL_VERSION) {
    return {
      ok: false,
      reason: `unsupported plugin protocolVersion ${manifest.protocolVersion} (this index supports ${PLUGINS_PROTOCOL_VERSION})`
    }
  }
  if (!PLUGIN_ID_PATTERN.test(manifest.id)) {
    return {
      ok: false,
      reason: `plugin id must be lowercase "owner.name" (letters, digits, hyphens): ${manifest.id}`
    }
  }
  // Anti-impersonation: the id's namespace must be the repo owner, so a repo
  // can never publish under someone else's plugin id.
  const namespace = manifest.id.split(".")[0]
  if (namespace !== repoOwner.toLowerCase()) {
    return {
      ok: false,
      reason: `plugin id "${manifest.id}" must be namespaced under the repo owner ("${repoOwner.toLowerCase()}.…")`
    }
  }
  return { ok: true, manifest }
}

// -- Index refresh ---------------------------------------------------------------

const toEntry = (manifest: PluginManifest, repo: GitHubSearchRepo): PluginIndexEntry => ({
  id: manifest.id,
  name: manifest.name,
  version: manifest.version,
  ...(manifest.description !== undefined ? { description: manifest.description } : {}),
  panes: manifest.panes,
  ...(manifest.tools !== undefined ? { tools: manifest.tools } : {}),
  repo: repo.full_name,
  stars: repo.stargazers_count,
  pushedAt: repo.pushed_at
})

/// Replaces the stored index: the full document, one key per entry, and
/// deletion of entry keys whose plugin is no longer indexed — untagging a
/// repo (or breaking its manifest) drops it on the next poll.
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

/// The whole poll: paginated topic search → raw manifest fetch per repo →
/// validation (schema + owner match) → rebuilt KV index with per-entry
/// diagnostics for everything rejected. Fully injectable: GitHub traffic goes
/// through env.GITHUB_FETCH when set (tests), global fetch otherwise.
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
    const response = await fetchImpl(manifestUrl(repo), {
      headers: { "user-agent": "codevisor-cloud-plugin-indexer" }
    })
    if (response.status === 404) {
      rejected.push({
        repo: repo.full_name,
        reason: `${PLUGIN_MANIFEST_FILENAME} not found on the default branch`
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
    entries.push(toEntry(validated.manifest, repo))
  }
  entries.sort((a, b) => b.stars - a.stars || a.id.localeCompare(b.id))
  const index: PluginIndex = { generatedAt: new Date().toISOString(), entries, rejected }
  await writeIndex(env.PLUGIN_INDEX, index)
  return { generatedAt: index.generatedAt, indexed: entries.length, rejected: rejected.length }
}
