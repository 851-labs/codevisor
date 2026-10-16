import { join } from "node:path"

import type { HarnessDefinition } from "@codevisor/agent-runtime"
import type {
  NativeMcpHarnessServers,
  NativeMcpImportCandidate,
  NativeMcpScan,
  NativeMcpServer
} from "@codevisor/api"
import { resolveNativeConfigPath } from "@codevisor/skills"

import { errorMessage, run } from "./mcp-support.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"
import { getNestedValue, parseNativeConfig } from "./native-config-files.js"
import {
  extractServerIdentity,
  normalizeNativeServer,
  type NormalizedNativeServer
} from "./native-config-normalize.js"
import type { NativeMcpManagerConfig } from "./native-mcp-types.js"

export interface NativeMcpEnvironment {
  readonly fs: NativeConfigFileSystem
  readonly home: string
  readonly env: Readonly<Record<string, string | undefined>>
}

export interface DiscoveredServer {
  readonly row: NativeMcpServer
  readonly normalized: NormalizedNativeServer
}

export interface NativeMcpScanDetail {
  readonly scan: NativeMcpScan
  readonly discovered: ReadonlyArray<DiscoveredServer>
}

export interface NativeMcpScanner {
  readonly scan: () => Promise<NativeMcpScan>
  readonly scanDetailed: () => Promise<NativeMcpScanDetail>
}

const HIDDEN_CODEX_NATIVE_MCPS = new Set(["computer-use", "node_repl", "cua_repl"])

const isHiddenNativeMcp = (harnessId: string, serverName: string): boolean =>
  harnessId === "codex" && HIDDEN_CODEX_NATIVE_MCPS.has(serverName)

const discoveredServer = (
  definition: HarnessDefinition,
  options: {
    readonly configPath: string
    readonly managed: ReadonlySet<string>
    readonly normalized: NormalizedNativeServer
    readonly scope: "global" | "project"
    readonly serverName: string
  }
): DiscoveredServer => {
  const spec = definition.nativeMcp
  const identity = extractServerIdentity(options.normalized.raw)
  const writable = options.scope === "global" && spec?.writable === true
  return {
    normalized: options.normalized,
    row: {
      alreadyManaged: identity !== "" && options.managed.has(identity),
      args: options.normalized.args,
      ...(options.normalized.command === undefined ? {} : { command: options.normalized.command }),
      configPath: options.configPath,
      ...(options.normalized.enabled === undefined ? {} : { enabled: options.normalized.enabled }),
      envNames: Object.keys(options.normalized.env),
      harnessId: definition.id,
      harnessName: definition.name,
      headerNames: Object.keys(options.normalized.headers),
      identity,
      scope: options.scope,
      serverName: options.serverName,
      supportsDisable: writable && spec?.disableField !== undefined,
      supportsRemove: writable,
      transport: options.normalized.transport,
      ...(options.normalized.url === undefined ? {} : { url: options.normalized.url })
    }
  }
}

export const makeNativeMcpScanner = (
  config: NativeMcpManagerConfig,
  environment: NativeMcpEnvironment
): NativeMcpScanner => {
  const { env, fs, home } = environment

  const managedIdentities = async (): Promise<ReadonlySet<string>> => {
    const servers = await run(config.db.listMcpServers)
    const identities = new Set<string>()
    for (const server of servers) {
      const identity = extractServerIdentity({
        args: [...server.args],
        ...(server.command === undefined ? {} : { command: server.command }),
        ...(server.url === undefined ? {} : { url: server.url })
      })
      if (identity !== "") identities.add(identity)
    }
    return identities
  }

  const readServers = async (
    definition: HarnessDefinition,
    options: {
      readonly configPath: string
      readonly managed: ReadonlySet<string>
      readonly scope: "global" | "project"
    }
  ): Promise<{ readonly exists: boolean; readonly servers: ReadonlyArray<DiscoveredServer> }> => {
    const spec = definition.nativeMcp
    /* v8 ignore next */
    if (spec === undefined) return { exists: false, servers: [] }
    const content = await fs.readFile(options.configPath)
    if (content === undefined) return { exists: false, servers: [] }
    const parsed = parseNativeConfig(content, spec.format)
    const serversValue = getNestedValue(parsed, spec.key)
    if (serversValue === null || typeof serversValue !== "object" || Array.isArray(serversValue)) {
      return { exists: true, servers: [] }
    }
    const servers: Array<DiscoveredServer> = []
    for (const [serverName, raw] of Object.entries(serversValue)) {
      if (isHiddenNativeMcp(definition.id, serverName)) continue
      const normalized = normalizeNativeServer(definition.id, raw)
      if (normalized === undefined) continue
      servers.push(
        discoveredServer(definition, {
          configPath: options.configPath,
          managed: options.managed,
          normalized,
          scope: options.scope,
          serverName
        })
      )
    }
    return { exists: true, servers }
  }

  const readProjectServers = async (
    definition: HarnessDefinition,
    managed: ReadonlySet<string>
  ): Promise<ReadonlyArray<DiscoveredServer>> => {
    const projectFile = definition.nativeMcp?.projectFile
    if (projectFile === undefined) return []
    const projects = await run(config.db.listProjects)
    const folders = new Set<string>()
    for (const project of projects) {
      for (const location of project.locations) folders.add(location.folderPath)
    }
    const servers: Array<DiscoveredServer> = []
    for (const folder of [...folders].toSorted()) {
      const configPath = join(folder, projectFile)
      try {
        const result = await readServers(definition, {
          configPath,
          managed,
          scope: "project"
        })
        servers.push(...result.servers)
      } catch {}
    }
    return servers
  }

  const scanDetailed = async (): Promise<NativeMcpScanDetail> => {
    const managed = await managedIdentities()
    const harnesses: Array<NativeMcpHarnessServers> = []
    const discovered: Array<DiscoveredServer> = []

    for (const definition of config.agents.catalog) {
      const spec = definition.nativeMcp
      if (spec === undefined) continue
      const configPath = resolveNativeConfigPath(spec.path, { env, home })
      let exists = false
      let error: string | undefined
      let servers: ReadonlyArray<DiscoveredServer> = []
      try {
        const result = await readServers(definition, { configPath, managed, scope: "global" })
        exists = result.exists
        servers = result.servers
      } catch (cause) {
        exists = true
        error = errorMessage(cause)
      }
      const projectServers = await readProjectServers(definition, managed)
      const all = [...servers, ...projectServers]
      discovered.push(...all)
      harnesses.push({
        configPath,
        ...(error === undefined ? {} : { error }),
        exists,
        harnessId: definition.id,
        harnessName: definition.name,
        harnessSymbol: definition.symbolName,
        servers: all.map((server) => server.row)
      })
    }

    return { discovered, scan: { candidates: coalesceCandidates(discovered), harnesses } }
  }

  const scan = async (): Promise<NativeMcpScan> => (await scanDetailed()).scan

  return { scan, scanDetailed }
}

const coalesceCandidates = (
  discovered: ReadonlyArray<DiscoveredServer>
): ReadonlyArray<NativeMcpImportCandidate> => {
  const byIdentity = new Map<
    string,
    { candidate: NativeMcpImportCandidate; foundIn: Array<string> }
  >()
  for (const { normalized, row } of discovered) {
    /* v8 ignore next 2 */
    if (row.identity === "") continue
    const existing = byIdentity.get(row.identity)
    if (existing !== undefined) {
      if (!existing.foundIn.includes(row.harnessId)) existing.foundIn.push(row.harnessId)
      continue
    }
    const foundIn = [row.harnessId]
    byIdentity.set(row.identity, {
      candidate: {
        alreadyManaged: row.alreadyManaged,
        args: normalized.args,
        ...(normalized.command === undefined ? {} : { command: normalized.command }),
        foundIn,
        identity: row.identity,
        name: row.serverName,
        transport: normalized.transport,
        ...(normalized.url === undefined ? {} : { url: normalized.url })
      },
      foundIn
    })
  }
  return [...byIdentity.values()]
    .map(({ candidate, foundIn }) => ({ ...candidate, foundIn: [...foundIn] }))
    .toSorted((a, b) => a.name.localeCompare(b.name))
}
