import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import {
  grafanaServer,
  linearServer,
  pluginsFixture,
  registryFetch,
  testEventsServer
} from "./catalog-test-support.js"
import { makeCatalog, makeRegistryClient, readLocalCatalog } from "./index.js"

const githubServer = {
  name: "io.github.acme/github",
  title: "GitHub",
  description: "Repos and issues",
  version: "2.0.0",
  packages: [
    {
      registryType: "npm",
      identifier: "@acme/github-mcp",
      version: "2.0.0",
      transport: { type: "stdio" },
      environmentVariables: [{ name: "GITHUB_TOKEN", isSecret: true, isRequired: true }]
    }
  ]
}

const searchPath = (query: string) =>
  `/v0/servers?${new URLSearchParams({ search: query, version: "latest", limit: "30" }).toString()}`

const catalogFor = (
  root: string,
  responses: Readonly<Record<string, unknown>> = {},
  dev = false
) => {
  const fake = registryFetch(responses)
  const catalog = makeCatalog({
    dev,
    execPath: "/opt/node",
    workingDirectory: root,
    moduleDirectory: join(root, "elsewhere"),
    registry: makeRegistryClient({ baseUrl: "https://registry.test", fetch: fake.fetch })
  })
  return { catalog, requests: fake.requests }
}

describe("plugin catalog", () => {
  it("features first-party plugins, then the popular list, hiding dev-only ones", () => {
    const root = pluginsFixture()
    expect(
      catalogFor(root)
        .catalog.entries()
        .map((entry) => [entry.id, entry.source])
    ).toEqual([
      ["dev.codevisor/grafana", "first-party"],
      ["app.linear/linear", "popular"]
    ])
    expect(
      catalogFor(root, {}, true)
        .catalog.entries()
        .map((entry) => entry.id)
    ).toContain(testEventsServer.name)
  })

  it("launches bundled plugins with the server's runtime from the plugins folder", () => {
    const root = pluginsFixture()
    const { catalog } = catalogFor(root, {}, true)
    expect(catalog.bundledLaunch(grafanaServer.name)).toEqual({
      transport: "stdio",
      command: "/opt/node",
      args: [join(root, "plugins", "grafana", "dist", "main.js")]
    })
    expect(catalog.bundledLaunch(testEventsServer.name)?.args).toEqual([
      join(root, "plugins", "test-events", "dist", "server.js")
    ])
    expect(catalog.bundledLaunch(linearServer.name)).toBeUndefined()
  })

  it("adds official registry results to featured matches when searching", async () => {
    const root = pluginsFixture()
    const { catalog, requests } = catalogFor(root, {
      [searchPath("git")]: {
        servers: [
          { server: { ...githubServer, version: "1.0.0" } },
          { server: githubServer },
          { server: grafanaServer }
        ]
      },
      [searchPath("linear")]: { servers: [{ server: linearServer }] }
    })
    expect(
      (await catalog.search("git")).map((entry) => [entry.id, entry.version, entry.source])
    ).toEqual([["io.github.acme/github", "2.0.0", "registry"]])
    expect((await catalog.search("linear")).map((entry) => entry.source)).toEqual(["popular"])
    expect((await catalog.search(undefined)).length).toBe(2)
    expect(await catalog.search("git")).toHaveLength(1)
    expect(requests.filter((request) => request === searchPath("git"))).toHaveLength(1)
  })

  it("resolves an id from the featured list or the registry", async () => {
    const root = pluginsFixture()
    const { catalog } = catalogFor(root, {
      "/v0/servers/io.github.acme%2Fgithub/versions/latest": { server: githubServer },
      "/v0/servers/dev.codevisor%2Fgrafana/versions/latest": { server: grafanaServer }
    })
    expect((await catalog.resolve(linearServer.name))?.source).toBe("popular")
    expect((await catalog.resolve("io.github.acme/github"))?.install.kind).toBe("package")
    expect(await catalog.resolve("missing/server")).toBeUndefined()
    expect(await catalog.resolve("dev.codevisor/grafana-copy")).toBeUndefined()
  })

  it("replaces the popular list with the one the cloud publishes", () => {
    const root = pluginsFixture()
    const { catalog } = catalogFor(root)
    catalog.publish([grafanaServer, { ...linearServer, name: "com.notion/mcp", title: "Notion" }])
    expect(catalog.entries().map((entry) => entry.name)).toEqual(["Grafana", "Notion"])
  })

  it("works without a plugins folder or a registry", async () => {
    const root = pluginsFixture()
    const empty = makeCatalog({
      dev: false,
      execPath: "/opt/node",
      workingDirectory: join(root, "none"),
      moduleDirectory: join(root, "none")
    })
    expect(empty.entries()).toEqual([])
    expect(await empty.search("anything")).toEqual([])
    expect(await empty.resolve("anything")).toBeUndefined()
    expect(
      readLocalCatalog({
        workingDirectory: join(root, "none"),
        moduleDirectory: join(root, "none")
      }).root
    ).toBe("")
  })
})

describe("plugin catalog files", () => {
  it("skips unreadable server files, plain files and entries it can't run", () => {
    const root = pluginsFixture([grafanaServer], [linearServer, { name: "app.example/nothing" }])
    writeFileSync(join(root, "plugins", "README.md"), "plugins")
    mkdirSync(join(root, "plugins", "broken"))
    writeFileSync(join(root, "plugins", "broken", "server.json"), "{ not json")
    expect(
      catalogFor(root)
        .catalog.entries()
        .map((entry) => entry.id)
    ).toEqual([grafanaServer.name, linearServer.name])
  })

  it("finds the repository's plugins folder from the working directory by default", () => {
    expect(readLocalCatalog().popular.length).toBeGreaterThan(0)
  })
})

const failing: typeof fetch = async () => {
  throw new TypeError("offline")
}

describe("official registry client", () => {
  it("treats network failures as no results", async () => {
    const registry = makeRegistryClient({ baseUrl: "https://registry.test", fetch: failing })
    expect(await registry.search("linear")).toEqual([])
    expect(await registry.server("app.linear/linear")).toBeUndefined()
  })
})

describe("official registry client defaults", () => {
  it("uses the global fetch and caches results", async () => {
    const calls: Array<string> = []
    vi.stubGlobal("fetch", async (input: URL) => {
      calls.push(String(input))
      return new Response(JSON.stringify({ servers: [{ server: linearServer }] }))
    })
    try {
      const registry = makeRegistryClient({ baseUrl: "https://registry.test" })
      expect((await registry.search("linear")).map((server) => server.name)).toEqual([
        linearServer.name
      ])
      await registry.search("linear")
      expect(calls).toHaveLength(1)
    } finally {
      vi.unstubAllGlobals()
    }
  })
})
