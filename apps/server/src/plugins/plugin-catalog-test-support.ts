import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { listenOn } from "../infra/mcp-oauth-test-support.js"
import { tempDirs } from "../test-support.js"
import type { PluginCatalogOptions } from "./plugin-catalog.js"

export type FixtureServer = Readonly<Record<string, unknown>> & { readonly name: string }

export const registryUrl = "https://registry.test"
export const cloudUrl = "https://cloud.test"

export const alertsServer: FixtureServer = {
  name: "dev.codevisor/alerts",
  title: "Alerts",
  description: "Watch alert rules",
  version: "2.0.0",
  _meta: {
    "dev.codevisor/plugin": {
      bundled: "alerts",
      accounts: {
        label: "Alerts instance",
        fields: [{ key: "url", label: "Alerts URL", type: "url", required: true }]
      },
      capabilities: {
        tools: [{ name: "list_rules", description: "List alert rules" }],
        events: [{ name: "rule.firing" }],
        skills: [],
        panes: [],
        ingress: []
      }
    }
  }
}

export const devToolServer: FixtureServer = {
  name: "dev.codevisor/devtool",
  title: "Dev Tool",
  version: "1.0.0",
  _meta: { "dev.codevisor/plugin": { bundled: "devtool", devOnly: true } }
}

export const ticketsServer: FixtureServer = {
  name: "io.example/tickets",
  title: "Tickets",
  description: "Track tickets",
  version: "1.0.0",
  remotes: [
    {
      type: "streamable-http",
      url: "http://remote.invalid/tickets",
      headers: [{ name: "Authorization", isRequired: true, isSecret: true }]
    }
  ]
}

export const weatherServer: FixtureServer = {
  name: "io.example/weather",
  title: "Weather",
  description: "Forecasts",
  version: "1.2.0",
  packages: [
    {
      registryType: "npm",
      identifier: "@example/weather",
      version: "1.2.0",
      runtimeHint: "/usr/bin/false",
      environmentVariables: [
        { name: "WEATHER_KEY", isRequired: true, isSecret: true },
        { name: "WEATHER_REGION", default: "eu" }
      ],
      packageArguments: [
        { type: "positional", isRequired: true, valueHint: "cache directory" },
        { type: "named", name: "units", value: "metric" }
      ]
    }
  ]
}

export const openServer: FixtureServer = {
  name: "io.example/open",
  title: "Open",
  remotes: [{ type: "streamable-http", url: "http://remote.invalid/open" }]
}

export const smuggledBundleServer: FixtureServer = {
  name: "io.example/smuggled",
  title: "Smuggled",
  _meta: { "dev.codevisor/plugin": { bundled: "../../etc" } }
}

export const publishedServer: FixtureServer = {
  name: "io.example/published",
  title: "Published",
  remotes: [{ type: "streamable-http", url: "http://remote.invalid/published" }]
}

export interface CatalogFixture {
  readonly remoteUrl: string
  readonly options: Omit<PluginCatalogOptions, "dev">
  readonly requests: ReadonlyArray<string>
  readonly respond: (url: string, body: unknown) => void
}

export const catalogFixture = async (
  firstParty: ReadonlyArray<FixtureServer> = [alertsServer, devToolServer],
  popular: ReadonlyArray<FixtureServer> = [ticketsServer]
): Promise<CatalogFixture> => {
  const remoteUrl = await listenOn((_request, response) => {
    response.statusCode = 404
    response.end()
  })
  const local = (value: unknown): unknown => withRemote(value, remoteUrl)
  const root = pluginsFolder(firstParty, popular, remoteUrl)
  const responses = new Map<string, unknown>(
    registryResponses().map(([url, body]) => [url, local(body)] as const)
  )
  const requests: Array<string> = []
  const fake = async (input: string | URL | Request): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input)
    requests.push(url)
    const body = responses.get(url)
    if (body instanceof Error) throw body
    if (body instanceof Response) return body
    if (body === undefined) return new Response("missing", { status: 404 })
    return Response.json(body)
  }
  return {
    remoteUrl,
    options: {
      execPath: "/usr/bin/false",
      moduleDirectory: join(root, "packages", "plugins", "dist", "catalog"),
      registryUrl,
      fetch: fake
    },
    requests,
    respond: (url, body) => {
      responses.set(url, local(body))
    }
  }
}

export const listed = (...servers: ReadonlyArray<FixtureServer>) => ({
  servers: servers.map((server) => ({ server }))
})

export const searchUrl = (query: string): string =>
  `${registryUrl}/v0/servers?search=${encodeURIComponent(query)}&version=latest&limit=30`

const lookupUrl = (name: string): string =>
  `${registryUrl}/v0/servers/${encodeURIComponent(name)}/versions/latest`

const remotePlaceholder = "http://remote.invalid"

const withRemote = (value: unknown, remoteUrl: string): unknown => {
  if (value instanceof Response || value instanceof Error || value === undefined) return value
  return JSON.parse(remoteJson(value, remoteUrl))
}

const remoteJson = (value: unknown, remoteUrl: string): string =>
  JSON.stringify(value).replaceAll(remotePlaceholder, remoteUrl)

const registryResponses = (): ReadonlyArray<readonly [string, unknown]> => [
  [searchUrl("weather"), listed(weatherServer, openServer, smuggledBundleServer, alertsServer)],
  [lookupUrl(weatherServer.name), { server: weatherServer }],
  [lookupUrl(openServer.name), { server: openServer }],
  [lookupUrl(smuggledBundleServer.name), { server: smuggledBundleServer }]
]

const pluginsFolder = (
  firstParty: ReadonlyArray<FixtureServer>,
  popular: ReadonlyArray<FixtureServer>,
  remoteUrl: string
): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-plugin-catalog-"))
  tempDirs.push(root)
  const plugins = join(root, "plugins")
  mkdirSync(plugins)
  writeFileSync(join(plugins, "popular.json"), remoteJson(listed(...popular), remoteUrl))
  for (const server of firstParty) {
    const folder = join(plugins, server.name.slice(server.name.indexOf("/") + 1))
    mkdirSync(folder)
    writeFileSync(join(folder, "server.json"), remoteJson(server, remoteUrl))
  }
  return root
}
