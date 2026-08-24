import type { PluginRegistryIndex } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  DEFAULT_PLUGIN_REGISTRY_URL,
  filterPluginRegistryIndex,
  makePluginRegistryClient,
  PLUGIN_REGISTRY_CACHE_TTL_MS,
  resolvePluginRegistryUrl
} from "./plugin-registry.js"
import { PluginsError } from "./plugins-error.js"

const index = (generatedAt: string): PluginRegistryIndex => ({
  generatedAt,
  entries: [
    {
      commit: "a".repeat(40),
      id: "acme.git-diff",
      name: "Git Diff",
      version: "0.1.0",
      description: "Live git diff viewer",
      panes: [{ path: "/panes/diff/", title: "Git Diff", type: "diff" }],
      protocolVersion: 1,
      tools: [{ description: "Summarize the diff", name: "diff_summary", path: "/tools/summary" }],
      repo: "acme/git-diff",
      stars: 12,
      pushedAt: "2026-08-17T00:00:00Z"
    },
    {
      commit: "b".repeat(40),
      id: "beta.notes",
      name: "Notes",
      version: "1.0.0",
      panes: [],
      protocolVersion: 1,
      repo: "beta/notes-plugin",
      stars: 3,
      pushedAt: "2026-08-16T00:00:00Z"
    }
  ],
  rejected: [{ reason: "codevisor-plugin.json not found on the default branch", repo: "x/y" }]
})

const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status
  })

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("resolvePluginRegistryUrl", () => {
  it("prefers the explicit override, then the dev cloud, then production", () => {
    expect(
      resolvePluginRegistryUrl({
        CODEVISOR_DEV_CLOUD_URL: "http://127.0.0.1:8787",
        CODEVISOR_PLUGIN_REGISTRY_URL: "https://registry.example/"
      })
    ).toBe("https://registry.example")
    expect(resolvePluginRegistryUrl({ CODEVISOR_DEV_CLOUD_URL: "http://127.0.0.1:8787/" })).toBe(
      "http://127.0.0.1:8787"
    )
    expect(resolvePluginRegistryUrl({})).toBe(DEFAULT_PLUGIN_REGISTRY_URL)
  })
})

describe("makePluginRegistryClient", () => {
  it("fetches /plugins/index.json once and serves the cached index while fresh", async () => {
    const urls: Array<string> = []
    let clock = 0
    const client = makePluginRegistryClient({
      baseUrl: "https://registry.example/",
      fetchImpl: async (url) => {
        urls.push(url)
        return jsonResponse(index("first"))
      },
      now: () => clock
    })
    expect((await client.fetchIndex()).generatedAt).toBe("first")
    clock = PLUGIN_REGISTRY_CACHE_TTL_MS - 1
    expect((await client.fetchIndex()).generatedAt).toBe("first")
    expect(urls).toEqual(["https://registry.example/plugins/index.json"])
  })

  it("refetches after the TTL elapses", async () => {
    let clock = 0
    let calls = 0
    const client = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => jsonResponse(index(`fetch-${(calls += 1)}`)),
      now: () => clock
    })
    expect((await client.fetchIndex()).generatedAt).toBe("fetch-1")
    clock = PLUGIN_REGISTRY_CACHE_TTL_MS
    expect((await client.fetchIndex()).generatedAt).toBe("fetch-2")
    expect(calls).toBe(2)
  })

  it("never caches a never-generated index (generatedAt null)", async () => {
    // The cloud serves { generatedAt: null } before its first poll. Pinning
    // that empty answer for a TTL would show "no plugins published" for 10
    // minutes on fresh dev environments, so it is served but not cached.
    let calls = 0
    const client = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => {
        calls += 1
        return calls === 1
          ? jsonResponse({ entries: [], generatedAt: null, rejected: [] })
          : jsonResponse(index("first-poll"))
      },
      now: () => 0
    })
    expect((await client.fetchIndex()).generatedAt).toBeNull()
    // Same instant, no TTL elapsed: the empty answer was not cached.
    expect((await client.fetchIndex()).generatedAt).toBe("first-poll")
    expect(calls).toBe(2)
  })

  it("serves the stale index when a refresh fails", async () => {
    let clock = 0
    let calls = 0
    const client = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => {
        calls += 1
        if (calls > 1) {
          throw new Error("network down")
        }
        return jsonResponse(index("cached"))
      },
      now: () => clock
    })
    expect((await client.fetchIndex()).generatedAt).toBe("cached")
    clock = PLUGIN_REGISTRY_CACHE_TTL_MS + 1
    // Stale-while-error: the expired entry still answers.
    expect((await client.fetchIndex()).generatedAt).toBe("cached")
    expect(calls).toBe(2)
  })

  it("fails as a typed unavailable error when nothing was ever cached", async () => {
    const failing = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => {
        throw new Error("network down")
      }
    })
    const failure = await failing.fetchIndex().then(
      () => undefined,
      (cause: unknown) => cause
    )
    expect(failure).toBeInstanceOf(PluginsError)
    expect((failure as PluginsError).code).toBe("unavailable")
    expect((failure as PluginsError).message).toContain("network down")

    // Non-Error throwables surface as their string form.
    const throwsValue = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => {
        throw "boom"
      }
    })
    await expect(throwsValue.fetchIndex()).rejects.toThrow("Plugin registry is unreachable: boom")
  })

  it("treats non-2xx answers and malformed indexes as unavailable", async () => {
    const teapot = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => jsonResponse({ error: "nope" }, 503)
    })
    await expect(teapot.fetchIndex()).rejects.toThrow("status 503")

    // A 200 whose body does not match the wire schema is just as unusable —
    // including non-Error decode throws surfacing as their string form.
    const malformed = makePluginRegistryClient({
      baseUrl: "https://registry.example",
      fetchImpl: async () => jsonResponse({ entries: "not-an-array" })
    })
    const failure = await malformed.fetchIndex().then(
      () => undefined,
      (cause: unknown) => cause
    )
    expect(failure).toBeInstanceOf(PluginsError)
    expect((failure as PluginsError).code).toBe("unavailable")
  })

  it("defaults to global fetch and the real clock", async () => {
    const fetchMock = vi.fn(async () => jsonResponse(index("global")))
    vi.stubGlobal("fetch", fetchMock)
    const client = makePluginRegistryClient({ baseUrl: "https://registry.example" })
    expect((await client.fetchIndex()).generatedAt).toBe("global")
    // The fresh cache answers without touching fetch again.
    expect((await client.fetchIndex()).generatedAt).toBe("global")
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe("filterPluginRegistryIndex", () => {
  it("matches case-insensitively across id, name, description, and repo", () => {
    const full = index("now")
    expect(filterPluginRegistryIndex(full, "GIT").entries.map((entry) => entry.id)).toEqual([
      "acme.git-diff"
    ])
    // "notes-plugin" only appears in the repo; the entry has no description.
    expect(
      filterPluginRegistryIndex(full, "notes-plugin").entries.map((entry) => entry.id)
    ).toEqual(["beta.notes"])
    expect(filterPluginRegistryIndex(full, "viewer").entries.map((entry) => entry.id)).toEqual([
      "acme.git-diff"
    ])
    expect(filterPluginRegistryIndex(full, "zzz").entries).toEqual([])
    // Diagnostics pass through untouched so the wire shape never changes.
    expect(filterPluginRegistryIndex(full, "zzz").rejected).toEqual(full.rejected)
  })

  it("returns the index unchanged for blank queries", () => {
    const full = index("now")
    expect(filterPluginRegistryIndex(full, "   ")).toBe(full)
  })
})
