import type { IncomingMessage, ServerResponse } from "node:http"

import {
  InstallCatalogPluginRequest,
  type ConfigField,
  type CreateMcpServerRequest,
  type McpServer,
  type PluginCatalogEntry
} from "@codevisor/api"
import { CATALOG_STDIO_COMMAND, type McpManager } from "@codevisor/mcp"

import { splitFieldValues } from "../plugins/accounts/plugin-account-fields.js"
import type { PluginCatalog } from "../plugins/plugin-catalog.js"
import {
  HttpFailure,
  matchRoute,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routePluginCatalog = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/plugins/catalog")) return false
  const catalog = requireCatalog(services)

  if (url.pathname === "/v1/plugins/catalog" && request.method === "GET") {
    writeJson(response, 200, {
      entries: await catalog.search(url.searchParams.get("query") ?? undefined)
    })
    return true
  }

  const entryId = matchRoute(url.pathname, "/v1/plugins/catalog/:id")
  if (entryId !== undefined && request.method === "GET") {
    writeJson(response, 200, await requireEntry(catalog, entryId))
    return true
  }

  const installId = matchRoute(url.pathname, "/v1/plugins/catalog/:id/install")
  if (installId === undefined || request.method !== "POST") return false

  const body = await readSchema(request, InstallCatalogPluginRequest)
  writeJson(
    response,
    200,
    await installCatalogPlugin(requireMcp(services), catalog, installId, body.values ?? {})
  )
  return true
}

const requireEntry = async (catalog: PluginCatalog, id: string): Promise<PluginCatalogEntry> => {
  const entry = await catalog.resolve(id)
  if (entry === undefined) throw new HttpFailure(404, `Unknown plugin: ${id}`)
  return entry
}

export const installCatalogPlugin = async (
  mcp: McpManager,
  catalog: PluginCatalog,
  catalogId: string,
  values: Readonly<Record<string, unknown>>
): Promise<McpServer> => {
  const entry = await requireEntry(catalog, catalogId)
  const installed = (await mcp.list()).find((server) => server.catalogId === entry.id)
  if (installed !== undefined) return installed

  return mcp.create(creationFor(entry, values))
}

export const creationFor = (
  entry: PluginCatalogEntry,
  values: Readonly<Record<string, unknown>>
): CreateMcpServerRequest => {
  const base = { name: entry.name, catalogId: entry.id, catalogVersion: entry.version }
  const install = entry.install
  if (install.kind === "bundled") {
    return { ...base, transport: "stdio", command: CATALOG_STDIO_COMMAND, args: [entry.id] }
  }
  const filled = filledFields(install.fields, values)
  if (install.kind === "remote") {
    return {
      ...base,
      transport: "http",
      url: install.url,
      ...nonEmpty("headers", prefixed(filled, "header:"))
    }
  }
  return {
    ...base,
    transport: "stdio",
    command: install.command,
    args: substitutedArgs(install.args, prefixed(filled, "arg:")),
    ...nonEmpty("env", prefixed(filled, "env:"))
  }
}

const filledFields = (
  fields: ReadonlyArray<ConfigField>,
  values: Readonly<Record<string, unknown>>
): Readonly<Record<string, string>> => {
  const split = splitFieldValues(fields, values)
  return Object.fromEntries(
    Object.entries({ ...split.values, ...split.secrets }).map(([key, value]) => [
      key,
      String(value)
    ])
  )
}

const prefixed = (
  filled: Readonly<Record<string, string>>,
  prefix: string
): Readonly<Record<string, string>> =>
  Object.fromEntries(
    Object.entries(filled)
      .filter(([key]) => key.startsWith(prefix))
      .map(([key, value]) => [key.slice(prefix.length), value])
  )

export const substitutedArgs = (
  args: ReadonlyArray<string>,
  provided: Readonly<Record<string, string>>
): ReadonlyArray<string> =>
  args.flatMap((arg) => {
    const placeholder = /^\$\{arg:(\d+)\}$/.exec(arg)
    if (placeholder === null) return [arg]
    const value = provided[placeholder[1]!]
    return value === undefined ? [] : [value]
  })

const nonEmpty = <K extends string>(
  key: K,
  record: Readonly<Record<string, string>>
): Partial<Record<K, Readonly<Record<string, string>>>> => {
  if (Object.keys(record).length === 0) return {}
  const filled: Partial<Record<K, Readonly<Record<string, string>>>> = {}
  filled[key] = record
  return filled
}

const requireCatalog = (services: CodevisorServerServices): PluginCatalog => {
  if (services.pluginCatalog === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return services.pluginCatalog
}

const requireMcp = (services: CodevisorServerServices): McpManager => {
  if (services.mcp === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return services.mcp
}
