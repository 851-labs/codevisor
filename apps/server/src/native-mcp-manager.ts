import type {
  CreateMcpServerRequest,
  ImportNativeMcpsRequest,
  ImportNativeMcpsResult,
  NativeMcpHarnessServers,
  NativeMcpImportCandidate,
  NativeMcpImportOutcome,
  NativeMcpRemoval,
  NativeMcpScan,
  NativeMcpServer,
  RemoveNativeMcpResult
} from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService, NativeMcpRemovalRecord } from "@codevisor/db"
import type { McpManager } from "./mcp-manager.js"
import { createHash } from "node:crypto"
import { homedir } from "node:os"
import { basename, join } from "node:path"
import { Effect } from "effect"
import {
  appendTomlTable,
  defaultNativeConfigFileSystem,
  extractServerIdentity,
  getNestedValue,
  type NativeConfigFileSystem,
  NativeConfigUnsupportedError,
  normalizeNativeServer,
  type NormalizedNativeServer,
  parseNativeConfig,
  removeJsonConfigKey,
  removeTomlTable,
  resolveNativeConfigPath,
  setJsonConfigValue
} from "./native-config-files.js"

/// Discovery and import over MCP servers users registered directly in
/// harness config files. The scan surfaces what exists, dedupes it against
/// Codevisor-managed servers, and coalesces import candidates; import lifts
/// candidates into the managed gateway. Native files are never written.
export interface NativeMcpManager {
  readonly scan: () => Promise<NativeMcpScan>
  /// Import coalesced candidates by identity. Secret values are re-read from
  /// the native configs here, server-side — the client only ever sends the
  /// identity strings back.
  readonly importServers: (request: ImportNativeMcpsRequest) => Promise<ImportNativeMcpsResult>
  /// Remove a global server entry from a harness config file: one-time
  /// backup, surgical edit, atomic write, and the removed fragment parked
  /// for restore.
  readonly removeServer: (harnessId: string, serverName: string) => Promise<RemoveNativeMcpResult>
  readonly listRemovals: () => Promise<ReadonlyArray<NativeMcpRemoval>>
  /// Undo a removal: reinsert the parked fragment (refusing on a name
  /// collision) and mark it restored.
  readonly restoreRemoval: (id: string) => Promise<NativeMcpScan>
  /// Toggle a harness's own per-server enable flag — only offered where the
  /// harness has a real one (catalog disableField).
  readonly setNativeEnabled: (
    harnessId: string,
    serverName: string,
    enabled: boolean
  ) => Promise<NativeMcpScan>
}

/// Typed failure the HTTP layer maps to a status code: notFound → 404,
/// conflict → 409, unsupported → 422.
export class NativeMcpError extends Error {
  constructor(
    message: string,
    readonly code: "notFound" | "conflict" | "unsupported"
  ) {
    super(message)
    this.name = "NativeMcpError"
  }
}

/// The slice of McpManager import needs — narrow so tests can fake it
/// without a gateway, network, or OAuth machinery.
export type ImportTargetMcpManager = Pick<McpManager, "create" | "detectAuth">

export interface NativeMcpManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  /// The managed-MCP store imports create servers in.
  readonly mcp: ImportTargetMcpManager
  /// Where one-time pre-mutation backups of harness configs live
  /// (<dataDir>/native-config-backups/).
  readonly dataDir: string
  /// Seams for tests; production uses the real home dir, process env, and fs.
  readonly homedir?: string
  readonly env?: Readonly<Record<string, string | undefined>>
  readonly fs?: NativeConfigFileSystem
}

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

interface DiscoveredServer {
  readonly row: NativeMcpServer
  readonly normalized: NormalizedNativeServer
}

export const makeNativeMcpManager = (config: NativeMcpManagerConfig): NativeMcpManager => {
  const fs = config.fs ?? defaultNativeConfigFileSystem
  const home = config.homedir ?? homedir()
  const env = config.env ?? process.env

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

  const scanDetailed = async (): Promise<{
    readonly scan: NativeMcpScan
    readonly discovered: ReadonlyArray<DiscoveredServer>
  }> => {
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

  /// Names already taken in the managed store, for collision suffixing.
  const managedNames = async (): Promise<Set<string>> => {
    const servers = await run(config.db.listMcpServers)
    return new Set(servers.map((server) => server.name.toLowerCase()))
  }

  const importServers = async (
    request: ImportNativeMcpsRequest
  ): Promise<ImportNativeMcpsResult> => {
    const { discovered, scan: current } = await scanDetailed()
    const names = await managedNames()
    const outcomes: Array<NativeMcpImportOutcome> = []

    for (const identity of request.identities) {
      const candidate = current.candidates.find((entry) => entry.identity === identity)
      if (candidate === undefined) {
        outcomes.push({
          detail: "Not found in any harness — rescan and try again",
          identity,
          status: "failed",
          warnings: []
        })
        continue
      }
      if (candidate.alreadyManaged) {
        outcomes.push({
          detail: "Already managed by Codevisor",
          identity,
          status: "skipped",
          warnings: []
        })
        continue
      }
      // Prefer the user-level registration when the same server also appears
      // in a project file.
      const source =
        discovered.find(
          (entry) => entry.row.identity === identity && entry.row.scope === "global"
        ) ?? (discovered.find((entry) => entry.row.identity === identity) as DiscoveredServer)

      try {
        outcomes.push(await importOne(identity, candidate.name, source, names))
      } catch (cause) {
        outcomes.push({
          detail: errorMessage(cause),
          identity,
          status: "failed",
          warnings: []
        })
      }
    }

    return { outcomes, scan: (await scanDetailed()).scan }
  }

  /// Secrets that reference shell variables were expanded by the harness at
  /// launch time; imported verbatim they stay literal — worth a warning.
  const placeholderWarnings = (normalized: NormalizedNativeServer): Array<string> => {
    const warnings: Array<string> = []
    for (const [key, value] of [
      ...Object.entries(normalized.env),
      ...Object.entries(normalized.headers)
    ]) {
      if (/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/.test(value)) {
        warnings.push(
          `${key} references a shell variable and was imported verbatim — review it in the server's settings`
        )
      }
    }
    return warnings
  }

  const importOne = async (
    identity: string,
    candidateName: string,
    source: DiscoveredServer,
    names: Set<string>
  ): Promise<NativeMcpImportOutcome> => {
    const { normalized, row } = source
    const warnings = placeholderWarnings(normalized)

    // Pick a free managed name: the native name, then a harness-suffixed one.
    let name = candidateName
    if (names.has(name.toLowerCase())) {
      name = `${candidateName} (${row.harnessName})`
    }
    if (names.has(name.toLowerCase())) {
      return {
        detail: `A managed server named ${candidateName} already exists — rename it first`,
        identity,
        status: "failed",
        warnings
      }
    }

    // Bare remote servers get an authorization probe so OAuth-protected ones
    // land in needsAuthorization with the existing Connect… flow ready. A
    // probe failure (offline, blocked) never fails the import.
    let authType: "none" | "bearer" | "oauth" = "none"
    if (normalized.url !== undefined && Object.keys(normalized.headers).length === 0) {
      try {
        const detection = await config.mcp.detectAuth(normalized.url)
        if (detection.authType === "oauth" || detection.authType === "bearer") {
          authType = detection.authType
        }
      } catch {
        warnings.push(
          "Couldn't probe the server's authorization requirements — imported without auth; connect it from settings"
        )
      }
    }

    const createRequest: CreateMcpServerRequest = {
      args: normalized.args,
      authType,
      ...(normalized.command === undefined ? {} : { command: normalized.command }),
      enabled: true,
      ...(Object.keys(normalized.env).length === 0 ? {} : { env: normalized.env }),
      ...(Object.keys(normalized.headers).length === 0 ? {} : { headers: normalized.headers }),
      name,
      transport: normalized.transport,
      ...(normalized.url === undefined ? {} : { url: normalized.url })
    }

    const created = await config.mcp.create(createRequest)
    names.add(created.name.toLowerCase())
    return {
      identity,
      serverId: created.id,
      serverName: created.name,
      status: "imported",
      warnings
    }
  }

  /// Catalog definition whose native config Codevisor may edit. All the
  /// destructive operations funnel through this gate.
  const writableDefinition = (
    harnessId: string
  ): {
    readonly definition: HarnessDefinition
    readonly spec: NonNullable<HarnessDefinition["nativeMcp"]>
  } => {
    const definition = config.agents.catalog.find((candidate) => candidate.id === harnessId)
    const spec = definition?.nativeMcp
    if (definition === undefined || spec === undefined) {
      throw new NativeMcpError(`${harnessId} has no native MCP support`, "notFound")
    }
    if (!spec.writable) {
      throw new NativeMcpError(
        `Codevisor can't edit ${definition.name}'s config safely yet — use Reveal in Finder`,
        "unsupported"
      )
    }
    return { definition, spec }
  }

  /// Read the global config for editing. The read happens immediately before
  /// each edit to shrink the race window against the harness rewriting its
  /// own file (Claude Code does so constantly).
  const readForEdit = async (
    spec: NonNullable<HarnessDefinition["nativeMcp"]>
  ): Promise<{ readonly configPath: string; readonly content: string }> => {
    const configPath = resolveNativeConfigPath(spec.path, { env, home })
    const content = await fs.readFile(configPath)
    if (content === undefined) {
      throw new NativeMcpError(`${configPath} does not exist`, "notFound")
    }
    return { configPath, content }
  }

  const entryFor = (
    spec: NonNullable<HarnessDefinition["nativeMcp"]>,
    content: string,
    serverName: string
  ): Record<string, unknown> | undefined => {
    const parsed = parseNativeConfig(content, spec.format)
    const servers = getNestedValue(parsed, spec.key)
    if (servers === null || (typeof servers === "object") === false || Array.isArray(servers)) {
      return undefined
    }
    const entry = (servers as Record<string, unknown>)[serverName]
    return entry !== null && typeof entry === "object" && !Array.isArray(entry)
      ? (entry as Record<string, unknown>)
      : undefined
  }

  /// One-time pre-mutation snapshot: taken from the exact content about to
  /// be edited, recorded first-write-wins, never overwritten afterwards.
  const ensureBackup = async (configPath: string, content: string): Promise<void> => {
    const existing = await run(config.db.getNativeConfigBackup(configPath))
    if (existing !== undefined) return
    const digest = createHash("sha1").update(configPath).digest("hex").slice(0, 12)
    const backupPath = join(
      config.dataDir,
      "native-config-backups",
      `${digest}-${basename(configPath)}`
    )
    await fs.writeFileAtomic(backupPath, content)
    await run(
      config.db.saveNativeConfigBackup({
        backupPath,
        createdAt: isoTimestamp(),
        filePath: configPath
      })
    )
  }

  const refuseUnsupported = <A>(operation: () => A): A => {
    try {
      return operation()
    } catch (cause) {
      /* v8 ignore next -- the surgical editors only throw NativeConfigUnsupportedError. */
      if (!(cause instanceof NativeConfigUnsupportedError)) throw cause
      throw new NativeMcpError(cause.message, "unsupported")
    }
  }

  // listRemovals excludes restored entries and fresh removals are never
  // restored, so restoredAt is always absent on records passing through here.
  const publicRemoval = (record: NativeMcpRemovalRecord): NativeMcpRemoval => ({
    configPath: record.configPath,
    harnessId: record.harnessId,
    id: record.id,
    removedAt: record.removedAt,
    serverName: record.serverName
  })

  const removeServer = async (
    harnessId: string,
    serverName: string
  ): Promise<RemoveNativeMcpResult> => {
    const { spec } = writableDefinition(harnessId)
    const { configPath, content } = await readForEdit(spec)
    const entry = entryFor(spec, content, serverName)
    if (entry === undefined) {
      throw new NativeMcpError(`No server named ${serverName} in ${configPath}`, "notFound")
    }
    const edited = refuseUnsupported(() =>
      spec.format === "json"
        ? removeJsonConfigKey(content, spec.key, serverName)
        : removeTomlTable(content, spec.key, serverName)
    )
    await ensureBackup(configPath, content)
    await fs.writeFileAtomic(configPath, edited)
    const removal = await run(
      config.db.saveNativeMcpRemoval({
        configPath,
        fragment: JSON.stringify(entry),
        harnessId,
        serverName
      })
    )
    return { removal: publicRemoval(removal), scan: await scan() }
  }

  const listRemovals = async (): Promise<ReadonlyArray<NativeMcpRemoval>> =>
    (await run(config.db.listNativeMcpRemovals())).map(publicRemoval)

  const restoreRemoval = async (id: string): Promise<NativeMcpScan> => {
    const record = (await run(config.db.listNativeMcpRemovals())).find(
      (candidate) => candidate.id === id
    )
    if (record === undefined) {
      throw new NativeMcpError("Removal not found or already restored", "notFound")
    }
    const { spec } = writableDefinition(record.harnessId)
    const configPath = resolveNativeConfigPath(spec.path, { env, home })
    const content = (await fs.readFile(configPath)) ?? ""
    if (entryFor(spec, content, record.serverName) !== undefined) {
      throw new NativeMcpError(
        `${record.serverName} already exists in ${configPath} — remove it first`,
        "conflict"
      )
    }
    const fragment = JSON.parse(record.fragment) as Record<string, unknown>
    const restored = refuseUnsupported(() =>
      spec.format === "json"
        ? setJsonConfigValue(content, [...spec.key.split("."), record.serverName], fragment)
        : appendTomlTable(content, spec.key, record.serverName, fragment)
    )
    await ensureBackup(configPath, content)
    await fs.writeFileAtomic(configPath, restored)
    await run(config.db.markNativeMcpRemovalRestored(id))
    return scan()
  }

  const setNativeEnabled = async (
    harnessId: string,
    serverName: string,
    enabled: boolean
  ): Promise<NativeMcpScan> => {
    const { definition, spec } = writableDefinition(harnessId)
    const disableField = spec.disableField
    if (disableField === undefined) {
      throw new NativeMcpError(
        `${definition.name} has no per-server enable flag — remove the server instead`,
        "unsupported"
      )
    }
    /* v8 ignore next 6 -- catalog invariant: every disableField harness is JSON today; the guard protects future TOML additions. */
    if (spec.format !== "json") {
      throw new NativeMcpError(
        `${definition.name}'s enable flag can't be edited safely yet`,
        "unsupported"
      )
    }
    const { configPath, content } = await readForEdit(spec)
    if (entryFor(spec, content, serverName) === undefined) {
      throw new NativeMcpError(`No server named ${serverName} in ${configPath}`, "notFound")
    }
    // enabledWhen describes which flag value means "enabled": opencode's
    // {enabled: true} vs cline's {disabled: false}.
    const flagValue = disableField.enabledWhen ? enabled : !enabled
    const edited = setJsonConfigValue(
      content,
      [...spec.key.split("."), serverName, disableField.name],
      flagValue
    )
    await ensureBackup(configPath, content)
    await fs.writeFileAtomic(configPath, edited)
    return scan()
  }

  return { importServers, listRemovals, removeServer, restoreRemoval, scan, setNativeEnabled }
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
