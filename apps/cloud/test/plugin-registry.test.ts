import {
  createExecutionContext,
  createScheduledController,
  env,
  SELF,
  waitOnExecutionContext
} from "cloudflare:test"
import { describe, expect, it } from "vitest"
import type { CloudEnv } from "../src/env.js"
import worker from "../src/index.js"
import {
  PLUGIN_INDEX_KEY,
  pluginEntryKey,
  refreshPluginIndex,
  validateManifestForIndex,
  type PluginIndex,
  type PluginIndexEntry
} from "../src/plugin-registry.js"

const BASE = "http://localhost:8787"
const SEARCH_URL = "https://api.github.com/search/repositories"

// -- Fixtures ------------------------------------------------------------------

const manifest = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
  protocolVersion: 1,
  id: "octocat.notes",
  name: "Notes",
  version: "1.2.0",
  description: "A notes pane",
  panes: [{ type: "notes", title: "Notes", path: "/notes/" }],
  tools: [{ name: "notes_add", description: "Add a note", path: "/tools/add" }],
  run: { command: "bun run start" },
  ...overrides
})

interface RepoFixture {
  owner: string
  name: string
  stars?: number
  pushedAt?: string
  branch?: string
  /// Raw manifest body served for this repo; a number means "respond with
  /// that HTTP status instead".
  manifest: string | number
}

const searchItem = (repo: RepoFixture): Record<string, unknown> => ({
  full_name: `${repo.owner}/${repo.name}`,
  default_branch: repo.branch ?? "main",
  stargazers_count: repo.stars ?? 0,
  pushed_at: repo.pushedAt ?? "2026-08-01T00:00:00Z",
  owner: { login: repo.owner }
})

interface StubFetch {
  fetch: NonNullable<CloudEnv["GITHUB_FETCH"]>
  requests: string[]
}

/// Serves the GitHub search API (paginated) and raw-content manifests from
/// in-memory fixtures — the whole pipeline runs with zero network.
const githubStub = (repos: RepoFixture[]): StubFetch => {
  const requests: string[] = []
  return {
    requests,
    fetch: (input) => {
      requests.push(input)
      const url = new URL(input)
      if (`${url.origin}${url.pathname}` === SEARCH_URL) {
        const perPage = Number(url.searchParams.get("per_page"))
        const page = Number(url.searchParams.get("page"))
        const items = repos.slice((page - 1) * perPage, page * perPage).map(searchItem)
        return Promise.resolve(Response.json({ total_count: repos.length, items }))
      }
      const match = /^https:\/\/raw\.githubusercontent\.com\/([^/]+)\/([^/]+)\//.exec(input)
      const repo = repos.find((r) => r.owner === match?.[1] && r.name === match?.[2])
      if (repo === undefined) return Promise.resolve(new Response("not found", { status: 404 }))
      if (typeof repo.manifest === "number") {
        return Promise.resolve(new Response("error", { status: repo.manifest }))
      }
      return Promise.resolve(new Response(repo.manifest))
    }
  }
}

const readIndex = async (): Promise<PluginIndex> => {
  const raw = await env.PLUGIN_INDEX.get(PLUGIN_INDEX_KEY)
  expect(raw).not.toBeNull()
  return JSON.parse(raw as string) as PluginIndex
}

// -- Manifest validation ---------------------------------------------------------

describe("manifest validation", () => {
  it("accepts a well-formed manifest owned by the repo owner", () => {
    const result = validateManifestForIndex(JSON.stringify(manifest()), "Octocat")
    expect(result).toMatchObject({ ok: true, manifest: { id: "octocat.notes" } })
  })

  it("rejects impersonation, bad ids, bad JSON, schema and protocol mismatches", () => {
    const cases: { raw: string; owner: string; reason: string }[] = [
      { raw: "not json {", owner: "octocat", reason: "not valid JSON" },
      {
        raw: JSON.stringify({ id: "octocat.notes" }),
        owner: "octocat",
        reason: "invalid plugin manifest"
      },
      {
        raw: JSON.stringify(manifest({ protocolVersion: 99 })),
        owner: "octocat",
        reason: "unsupported plugin protocolVersion 99"
      },
      {
        raw: JSON.stringify(manifest({ id: "NotLowercase" })),
        owner: "octocat",
        reason: 'lowercase "owner.name"'
      },
      {
        raw: JSON.stringify(manifest()),
        owner: "evil-fork",
        reason: 'must be namespaced under the repo owner ("evil-fork.…")'
      }
    ]
    for (const { raw, owner, reason } of cases) {
      const result = validateManifestForIndex(raw, owner)
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.reason).toContain(reason)
    }
  })
})

// -- Refresh pipeline ------------------------------------------------------------

describe("refreshPluginIndex", () => {
  it("indexes valid tagged repos and records diagnostics for the rest", async () => {
    const stub = githubStub([
      { owner: "octocat", name: "notes", stars: 3, manifest: JSON.stringify(manifest()) },
      {
        owner: "hubber",
        name: "clock",
        stars: 9,
        manifest: JSON.stringify(
          manifest({ id: "hubber.clock", name: "Clock", description: undefined, tools: undefined })
        )
      },
      // Impersonation attempt: a fork claiming octocat's id.
      { owner: "evil", name: "notes", manifest: JSON.stringify(manifest()) },
      // Second repo by the same owner claiming an already-indexed id.
      { owner: "octocat", name: "notes-fork", manifest: JSON.stringify(manifest()) },
      { owner: "octocat", name: "untagged-manifest", manifest: 404 },
      { owner: "octocat", name: "flaky", manifest: 500 },
      { owner: "octocat", name: "broken", manifest: "{ nope" }
    ])
    const summary = await refreshPluginIndex({
      ...env,
      GITHUB_FETCH: stub.fetch,
      GITHUB_TOKEN: "t"
    })
    expect(summary).toMatchObject({ indexed: 2, rejected: 5 })

    const index = await readIndex()
    expect(index.generatedAt).toBe(summary.generatedAt)
    // Sorted by stars descending.
    expect(index.entries.map((entry) => entry.id)).toEqual(["hubber.clock", "octocat.notes"])
    expect(index.entries[1]).toEqual({
      id: "octocat.notes",
      name: "Notes",
      version: "1.2.0",
      description: "A notes pane",
      panes: [{ type: "notes", title: "Notes", path: "/notes/" }],
      tools: [{ name: "notes_add", description: "Add a note", path: "/tools/add" }],
      repo: "octocat/notes",
      stars: 3,
      pushedAt: "2026-08-01T00:00:00Z"
    })
    // Optional fields are omitted, not null.
    expect(index.entries[0]).not.toHaveProperty("description")
    expect(index.entries[0]).not.toHaveProperty("tools")
    const reasons = Object.fromEntries(index.rejected.map((r) => [r.repo, r.reason]))
    expect(reasons["evil/notes"]).toContain("must be namespaced under the repo owner")
    expect(reasons["octocat/notes-fork"]).toContain("already indexed from octocat/notes")
    expect(reasons["octocat/untagged-manifest"]).toContain("not found on the default branch")
    expect(reasons["octocat/flaky"]).toContain("failed with status 500")
    expect(reasons["octocat/broken"]).toContain("not valid JSON")

    // Per-entry keys are written for /plugins/:id.json.
    const entry = await env.PLUGIN_INDEX.get(pluginEntryKey("octocat.notes"))
    expect(JSON.parse(entry as string)).toMatchObject({
      id: "octocat.notes",
      repo: "octocat/notes"
    })

    // The search carried the token and the topic query.
    const search = stub.requests.find((url) => url.startsWith(SEARCH_URL))
    expect(search).toContain(encodeURIComponent("topic:codevisor-plugin"))
  })

  it("paginates the search until a short page", async () => {
    const repos: RepoFixture[] = Array.from({ length: 101 }, (_, i) => ({
      owner: "octocat",
      name: `p${i}`,
      manifest: JSON.stringify(manifest({ id: `octocat.p${i}`, name: `P${i}` }))
    }))
    const stub = githubStub(repos)
    const summary = await refreshPluginIndex({ ...env, GITHUB_FETCH: stub.fetch })
    expect(summary.indexed).toBe(101)
    const searches = stub.requests.filter((url) => url.startsWith(SEARCH_URL))
    expect(searches).toHaveLength(2)
    expect(searches[0]).toContain("page=1")
    expect(searches[1]).toContain("page=2")
  })

  it("drops a plugin (and its entry key) once its repo is untagged", async () => {
    const tagged = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) },
      {
        owner: "hubber",
        name: "clock",
        manifest: JSON.stringify(manifest({ id: "hubber.clock", name: "Clock" }))
      }
    ])
    await refreshPluginIndex({ ...env, GITHUB_FETCH: tagged.fetch })
    expect(await env.PLUGIN_INDEX.get(pluginEntryKey("hubber.clock"))).not.toBeNull()

    // hubber/clock no longer carries the topic → next poll forgets it.
    const untagged = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) }
    ])
    await refreshPluginIndex({ ...env, GITHUB_FETCH: untagged.fetch })
    const index = await readIndex()
    expect(index.entries.map((entry) => entry.id)).toEqual(["octocat.notes"])
    expect(await env.PLUGIN_INDEX.get(pluginEntryKey("hubber.clock"))).toBeNull()
    expect(await env.PLUGIN_INDEX.get(pluginEntryKey("octocat.notes"))).not.toBeNull()
  })

  it("fails loudly (keeping the previous index) when the search API errors", async () => {
    const good = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) }
    ])
    await refreshPluginIndex({ ...env, GITHUB_FETCH: good.fetch })
    const failing: StubFetch["fetch"] = () =>
      Promise.resolve(new Response("rate limited", { status: 403 }))
    await expect(refreshPluginIndex({ ...env, GITHUB_FETCH: failing })).rejects.toThrow(
      "GitHub search failed with status 403"
    )
    expect((await readIndex()).entries).toHaveLength(1)
  })
})

// -- HTTP surface ----------------------------------------------------------------

describe("plugin registry routes", () => {
  const seed = async (): Promise<PluginIndexEntry> => {
    const stub = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) }
    ])
    await refreshPluginIndex({ ...env, GITHUB_FETCH: stub.fetch })
    return (await readIndex()).entries[0] as PluginIndexEntry
  }

  it("serves an honest empty index before the first poll", async () => {
    // KV writes persist across tests in this file; recreate "never polled".
    await env.PLUGIN_INDEX.delete(PLUGIN_INDEX_KEY)
    const response = await SELF.fetch(`${BASE}/plugins/index.json`)
    expect(response.status).toBe(200)
    expect(response.headers.get("content-type")).toContain("application/json")
    expect(response.headers.get("cache-control")).toContain("max-age=300")
    expect(await response.json()).toEqual({ generatedAt: null, entries: [], rejected: [] })
  })

  it("serves the index and per-plugin documents with cache headers", async () => {
    const entry = await seed()
    const index = await SELF.fetch(`${BASE}/plugins/index.json`)
    expect(index.status).toBe(200)
    expect(index.headers.get("cache-control")).toBe(
      "public, max-age=300, stale-while-revalidate=900"
    )
    expect(((await index.json()) as PluginIndex).entries).toEqual([entry])

    const single = await SELF.fetch(`${BASE}/plugins/octocat.notes.json`)
    expect(single.status).toBe(200)
    expect(single.headers.get("cache-control")).toContain("max-age=300")
    expect(await single.json()).toEqual(entry)

    expect((await SELF.fetch(`${BASE}/plugins/no.such.json`)).status).toBe(404)
  })

  it("refreshes on demand in dev auth mode and reports GitHub failures", async () => {
    const stub = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) }
    ])
    const refreshed = await worker.fetch(
      new Request(`${BASE}/plugins/refresh`, { method: "POST" }),
      { ...env, GITHUB_FETCH: stub.fetch }
    )
    expect(refreshed.status).toBe(200)
    expect(await refreshed.json()).toMatchObject({ indexed: 1, rejected: 0 })
    expect((await readIndex()).entries[0]?.id).toBe("octocat.notes")

    const failing: StubFetch["fetch"] = () => Promise.resolve(new Response("nope", { status: 500 }))
    const failed = await worker.fetch(new Request(`${BASE}/plugins/refresh`, { method: "POST" }), {
      ...env,
      GITHUB_FETCH: failing
    })
    expect(failed.status).toBe(502)
    expect(await failed.json()).toMatchObject({ error: expect.stringContaining("500") })
  })

  it("guards refresh outside dev auth: hidden without the secret, bearer-gated with it", async () => {
    const stub = githubStub([])
    const { DEV_AUTH: _devAuth, ...prodEnv } = { ...env, GITHUB_FETCH: stub.fetch }

    const hidden = await worker.fetch(
      new Request(`${BASE}/plugins/refresh`, { method: "POST" }),
      prodEnv
    )
    expect(hidden.status).toBe(404)

    const guarded = { ...prodEnv, PLUGINS_REFRESH_TOKEN: "s3cret" }
    const wrong = await worker.fetch(
      new Request(`${BASE}/plugins/refresh`, {
        method: "POST",
        headers: { authorization: "Bearer wrong" }
      }),
      guarded
    )
    expect(wrong.status).toBe(401)

    const right = await worker.fetch(
      new Request(`${BASE}/plugins/refresh`, {
        method: "POST",
        headers: { authorization: "Bearer s3cret" }
      }),
      guarded
    )
    expect(right.status).toBe(200)
    expect(await right.json()).toMatchObject({ indexed: 0 })
  })
})

// -- Scheduled poll ----------------------------------------------------------------

describe("scheduled poll", () => {
  it("rebuilds the index from the cron trigger", async () => {
    const stub = githubStub([
      { owner: "octocat", name: "notes", manifest: JSON.stringify(manifest()) }
    ])
    const ctx = createExecutionContext()
    worker.scheduled(
      createScheduledController({ cron: "*/15 * * * *" }),
      { ...env, GITHUB_FETCH: stub.fetch },
      ctx
    )
    await waitOnExecutionContext(ctx)
    expect((await readIndex()).entries.map((entry) => entry.id)).toEqual(["octocat.notes"])
  })
})
