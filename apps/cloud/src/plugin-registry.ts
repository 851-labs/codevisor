// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
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
  protocolVersion: number
  description?: string
  /// Manifest artwork path on the plugin's own server — only fetchable once
  /// the plugin is installed and running, so browse UIs prefer
  /// `ownerAvatarUrl`.
  iconPath?: string
  panes: readonly PluginPaneDescriptor[]
  tools?: readonly PluginToolDescriptor[]
  /// GitHub "owner/name" — the directory always shows the real repo owner.
  repo: string
  /// Exact commit used to fetch and validate this manifest.
  commit: string
  minCodevisorVersion?: string
  requirements?: PluginRequirements
  platforms?: readonly string[]
  /// GitHub avatar of the repo owner — the only artwork renderable before
  /// install.
  ownerAvatarUrl?: string
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
  owner: { login: string; avatar_url?: string } | null
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

/// Fetch the manifest from the exact commit advertised in the index. This
/// prevents a default-branch push from changing the candidate after consent.
const manifestUrl = (repo: GitHubSearchRepo, commit: string): string =>
  `https://raw.githubusercontent.com/${repo.full_name}/${commit}/${PLUGIN_MANIFEST_FILENAME}`

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
  let manifest: PluginManifest
  try {
    manifest = decode(PluginManifest)(json)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { ok: false, reason: `invalid plugin manifest: ${message}` }
  }
  if (
    manifest.protocolVersion === 2 &&
    (!isSemanticVersion(manifest.version) ||
      (manifest.minCodevisorVersion !== undefined &&
        !isSemanticVersion(manifest.minCodevisorVersion)))
  ) {
    return { ok: false, reason: "protocol v2 version fields must use strict SemVer" }
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

const toEntry = (
  manifest: PluginManifest,
  repo: GitHubSearchRepo,
  commit: string
): PluginIndexEntry => ({
  commit,
  id: manifest.id,
  name: manifest.name,
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
  // The owner's GitHub avatar rides along so browse UIs can show artwork
  // without running anything — search results already carry it, so this
  // costs zero extra requests.
  ...(repo.owner?.avatar_url !== undefined ? { ownerAvatarUrl: repo.owner.avatar_url } : {}),
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
