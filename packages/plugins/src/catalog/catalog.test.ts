import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  grafanaServer,
  linearServer,
  pluginsFixture,
  testEventsServer
} from "./catalog-test-support.js"
import { makeCatalog, readLocalCatalog } from "./index.js"

const catalogFor = (root: string, dev = false) =>
  makeCatalog({
    dev,
    execPath: "/opt/node",
    workingDirectory: root,
    moduleDirectory: join(root, "elsewhere")
  })

describe("plugin catalog", () => {
  it("features first-party plugins, then the popular list, hiding dev-only ones", () => {
    const root = pluginsFixture()
    expect(
      catalogFor(root)
        .entries()
        .map((entry) => [entry.id, entry.source])
    ).toEqual([
      ["dev.codevisor/grafana", "first-party"],
      ["app.linear/linear", "popular"]
    ])
    expect(
      catalogFor(root, true)
        .entries()
        .map((entry) => entry.id)
    ).toContain(testEventsServer.name)
  })

  it("launches bundled plugins with the server's runtime from the plugins folder", () => {
    const root = pluginsFixture()
    const catalog = catalogFor(root, true)
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

  it("searches only the curated list", () => {
    const catalog = catalogFor(pluginsFixture())
    expect(catalog.search("linear").map((entry) => [entry.id, entry.source])).toEqual([
      ["app.linear/linear", "popular"]
    ])
    expect(catalog.search("grafana alerts").map((entry) => entry.id)).toEqual([
      "dev.codevisor/grafana"
    ])
    expect(catalog.search("github")).toEqual([])
    expect(catalog.search(undefined)).toHaveLength(2)
    expect(catalog.entry("io.github.acme/github")).toBeUndefined()
  })

  it("replaces the popular list with the one the cloud publishes", () => {
    const root = pluginsFixture()
    const catalog = catalogFor(root)
    catalog.publish([grafanaServer, { ...linearServer, name: "com.notion/mcp", title: "Notion" }])
    expect(catalog.entries().map((entry) => entry.name)).toEqual(["Grafana", "Notion"])
  })

  it("works without a plugins folder", () => {
    const root = pluginsFixture()
    const empty = makeCatalog({
      dev: false,
      execPath: "/opt/node",
      workingDirectory: join(root, "none"),
      moduleDirectory: join(root, "none")
    })
    expect(empty.entries()).toEqual([])
    expect(empty.search("anything")).toEqual([])
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
        .entries()
        .map((entry) => entry.id)
    ).toEqual([grafanaServer.name, linearServer.name])
  })

  it("finds the repository's plugins folder from the working directory by default", () => {
    expect(readLocalCatalog().popular.length).toBeGreaterThan(0)
  })
})
