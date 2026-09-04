import type {
  NativeMcpHarnessServers,
  NativeMcpImportCandidate,
  NativeMcpScan,
  NativeMcpServer
} from "@codevisor/api"
import type { HarnessDefinition } from "@codevisor/agent-runtime"
import { join } from "node:path"
import { errorMessage, run } from "./mcp-support.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"
import {
  getNestedValue,
  parseNativeConfig,
  resolveNativeConfigPath
} from "./native-config-files.js"
import {
  extractServerIdentity,
  normalizeNativeServer,
  type NormalizedNativeServer
} from "./native-config-normalize.js"
import type { NativeMcpManagerConfig } from "./native-mcp-types.js"

/// The resolved seams every native-config reader and editor shares.
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
  /// The scan plus the normalized entries behind every row, for importers
  /// that need the secret values the public rows deliberately omit.
  readonly scanDetailed: () => Promise<NativeMcpScanDetail>
}

// These are ChatGPT/Codex's own automation transports. Codevisor disables
// them per thread in favor of its gateway, so offering them for import or
// management in MCP Settings would be misleading. Keep the rule scoped to
// Codex so an identically named user server in another harness stays visible.
const HIDDEN_CODEX_NATIVE_MCPS = new Set(["computer-use", "node_repl", "cua_repl"])

const isHiddenNativeMcp = (harnessId: string, serverName: string): boolean =>
  harnessId === "codex" && HIDDEN_CODEX_NATIVE_MCPS.has(serverName)

export const makeNativeMcpScanner = (
  config: NativeMcpManagerConfig,
  environment: NativeMcpEnvironment
): NativeMcpScanner => {
  const { env, fs, home } = environment

  /// Identities of Codevisor-managed servers, for `alreadyManaged` flags.
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

  const serverRow = (
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
        ...(options.normalized.command === undefined
          ? {}
          : { command: options.normalized.command }),
        configPath: options.configPath,
        ...(options.normalized.enabled === undefined
          ? {}
          : { enabled: options.normalized.enabled }),
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

  /// Read + normalize every server in one config file. Parse failures throw;
  /// the caller converts them to a per-harness `error` field.
  const readServers = async (
    definition: HarnessDefinition,
    options: {
      readonly configPath: string
      readonly managed: ReadonlySet<string>
      readonly scope: "global" | "project"
    }
  ): Promise<{ readonly exists: boolean; readonly servers: ReadonlyArray<DiscoveredServer> }> => {
    const spec = definition.nativeMcp
    /* v8 ignore next -- callers only pass definitions carrying nativeMcp. */
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
        serverRow(definition, {
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

  /// Project-scoped files (.mcp.json) for harnesses that declare one — read
  /// from every known project folder, deduped, always read-only.
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
    for (const folder of [...folders].sort()) {
      const configPath = join(folder, projectFile)
      try {
        const result = await readServers(definition, {
          configPath,
          managed,
          scope: "project"
        })
        servers.push(...result.servers)
      } catch {
        // A project's committed file being malformed is that project's
        // problem — never let it poison the whole scan.
      }
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

/// Group discovered servers by identity so the same server registered in
/// three harnesses becomes one import row listing all of its sources.
const coalesceCandidates = (
  discovered: ReadonlyArray<DiscoveredServer>
): ReadonlyArray<NativeMcpImportCandidate> => {
  const byIdentity = new Map<
    string,
    { candidate: NativeMcpImportCandidate; foundIn: Array<string> }
  >()
  for (const { normalized, row } of discovered) {
    /* v8 ignore next 2 -- defensive: normalized entries always carry a url or command, which yields a non-empty identity. */
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
    .sort((a, b) => a.name.localeCompare(b.name))
}
