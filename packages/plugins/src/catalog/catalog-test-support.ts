import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach } from "vitest"

import type { RegistryServer } from "./registry-server.js"

const roots: Array<string> = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true })
})

export const grafanaServer: RegistryServer = {
  name: "dev.codevisor/grafana",
  title: "Grafana",
  description: "Grafana alerts and queries",
  version: "1.0.0",
  _meta: {
    "dev.codevisor/plugin": {
      bundled: "grafana",
      accounts: { label: "Grafana instance", fields: [] },
      capabilities: {
        tools: [{ name: "list_alerts" }],
        events: [],
        skills: [],
        panes: [],
        ingress: [{ name: "alerts" }]
      }
    }
  }
}

export const testEventsServer: RegistryServer = {
  name: "dev.codevisor/test-events",
  title: "Test Events",
  version: "1.0.0",
  _meta: {
    "dev.codevisor/plugin": { bundled: "test-events", entry: "dist/server.js", devOnly: true }
  }
}

export const linearServer: RegistryServer = {
  name: "app.linear/linear",
  title: "Linear",
  description: "Issues",
  version: "1.0.2",
  remotes: [{ type: "streamable-http", url: "https://mcp.linear.app/mcp" }]
}

export const pluginsFixture = (
  firstParty: ReadonlyArray<RegistryServer> = [grafanaServer, testEventsServer],
  popular: ReadonlyArray<RegistryServer> = [linearServer]
): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-catalog-"))
  roots.push(root)
  const plugins = join(root, "plugins")
  mkdirSync(plugins, { recursive: true })
  writeFileSync(
    join(plugins, "popular.json"),
    JSON.stringify({ servers: popular.map((server) => ({ server })) })
  )
  for (const server of firstParty) {
    const folder = join(plugins, server.name.slice(server.name.indexOf("/") + 1))
    mkdirSync(folder)
    writeFileSync(join(folder, "server.json"), JSON.stringify(server))
  }
  mkdirSync(join(plugins, "kit"))
  return root
}
