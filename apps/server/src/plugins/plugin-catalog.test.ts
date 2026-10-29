import { describe, expect, it, vi } from "vitest"

import {
  catalogFixture,
  cloudUrl,
  listed,
  publishedServer,
  smuggledBundleServer
} from "./plugin-catalog-test-support.js"
import {
  catalogRefreshMs,
  isDevInstance,
  makePluginCatalog,
  startCatalogRefresh
} from "./plugin-catalog.js"

const ids = (entries: ReadonlyArray<{ readonly id: string }>) => entries.map((entry) => entry.id)

const fixtureCatalog = async (dev = false) => {
  const fixture = await catalogFixture()
  return { fixture, catalog: makePluginCatalog({ dev, ...fixture.options }) }
}

const publishedUrl = `${cloudUrl}/v0/servers`

describe("plugin catalog", () => {
  it("features the local first-party plugins and the popular list, hiding dev-only ones", async () => {
    const production = (await fixtureCatalog()).catalog
    const development = (await fixtureCatalog(true)).catalog

    expect(production.entries().map((entry) => [entry.id, entry.source])).toEqual([
      ["dev.codevisor/alerts", "first-party"],
      ["io.example/tickets", "popular"]
    ])
    expect(ids(development.entries())).toEqual([
      "dev.codevisor/alerts",
      "dev.codevisor/devtool",
      "io.example/tickets"
    ])
    expect(production.entry("dev.codevisor/alerts")).toMatchObject({
      name: "Alerts",
      version: "2.0.0",
      install: { kind: "bundled" },
      accounts: { label: "Alerts instance" }
    })
    expect(production.entry("io.example/weather")).toBeUndefined()
  })

  it("searches only the curated plugins, without asking anyone else", async () => {
    const { fixture, catalog } = await fixtureCatalog()

    const featured = catalog.search(undefined)
    const searched = catalog.search(" tickets ")
    const elsewhere = catalog.search("weather")

    expect(ids(featured)).toEqual(["dev.codevisor/alerts", "io.example/tickets"])
    expect(searched.map((entry) => [entry.id, entry.source])).toEqual([
      ["io.example/tickets", "popular"]
    ])
    expect(elsewhere).toEqual([])
    expect(fixture.requests).toEqual([])
  })

  it("launches bundled plugins from the plugins folder with the configured runtime", async () => {
    const { fixture, catalog } = await fixtureCatalog()

    expect(catalog.resolver.launch("dev.codevisor/alerts")).toEqual({
      transport: "stdio",
      command: fixture.options.execPath,
      args: [expect.stringMatching(/\/plugins\/alerts\/dist\/main\.js$/)]
    })
    expect(catalog.resolver.launch("io.example/tickets")).toBeUndefined()
  })

  it("replaces the popular plugins with the catalog the cloud publishes, minus bundles", async () => {
    const { fixture, catalog } = await fixtureCatalog()
    fixture.respond(publishedUrl, listed(publishedServer, smuggledBundleServer))

    await catalog.refreshPublished(cloudUrl)

    expect(ids(catalog.entries())).toEqual(["dev.codevisor/alerts", "io.example/published"])
    expect(fixture.requests).toEqual([publishedUrl])
  })

  it.each([
    { name: "has no catalog", reply: undefined },
    { name: "answers with something other than JSON", reply: new Response("<html>") },
    { name: "publishes an empty catalog", reply: listed() },
    { name: "can't be reached", reply: new TypeError("offline") }
  ])("keeps the catalog it has when the cloud $name", async ({ reply }) => {
    const { fixture, catalog } = await fixtureCatalog()
    if (reply !== undefined) fixture.respond(publishedUrl, reply)

    await catalog.refreshPublished(cloudUrl)
    await catalog.refreshPublished(undefined)

    expect(ids(catalog.entries())).toEqual(["dev.codevisor/alerts", "io.example/tickets"])
    expect(fixture.requests).toEqual([publishedUrl])
  })

  it("refreshes the published catalog now and then every hour until stopped", async () => {
    const { catalog } = await fixtureCatalog()
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    try {
      const asked = vi.fn(() => "not a url")
      const stop = startCatalogRefresh(catalog, asked)

      vi.advanceTimersByTime(catalogRefreshMs - 1)
      const beforeAnHour = asked.mock.calls.length
      vi.advanceTimersByTime(1)
      const afterAnHour = asked.mock.calls.length
      stop()
      vi.advanceTimersByTime(catalogRefreshMs)

      expect([beforeAnHour, afterAnHour, asked.mock.calls.length]).toEqual([1, 2, 2])
    } finally {
      vi.useRealTimers()
    }
  })

  it("treats a server started for a development instance as development", () => {
    expect(isDevInstance({ CODEVISOR_DEV_INSTANCE_ID: "dev-1" })).toBe(true)
    expect(isDevInstance({})).toBe(false)
  })

  it("finds the repository's plugins folder by default", () => {
    const catalog = makePluginCatalog({ dev: true, execPath: "/opt/node" })

    expect(ids(catalog.entries())).toContain("dev.codevisor/test-events")
  })

  it("never lists the repository's dev-only plugins outside development", () => {
    const published = ids(makePluginCatalog({ dev: false, execPath: "/opt/node" }).entries())

    expect(published).toContain("app.linear/linear")
    expect(published).not.toContain("dev.codevisor/test-events")
  })
})
