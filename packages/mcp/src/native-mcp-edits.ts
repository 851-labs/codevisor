import type { NativeMcpRemoval, NativeMcpScan, RemoveNativeMcpResult } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type { HarnessDefinition } from "@codevisor/agent-runtime"
import type { NativeMcpRemovalRecord } from "@codevisor/db"
import { createHash } from "node:crypto"
import { basename, join } from "node:path"
import { run } from "./mcp-support.js"
import {
  appendTomlTable,
  removeJsonConfigKey,
  removeTomlTable,
  setJsonConfigValue
} from "./native-config-edits.js"
import {
  getNestedValue,
  NativeConfigUnsupportedError,
  parseNativeConfig,
  resolveNativeConfigPath
} from "./native-config-files.js"
import type { NativeMcpEnvironment } from "./native-mcp-scan.js"
import {
  NativeMcpError,
  type NativeMcpManager,
  type NativeMcpManagerConfig
} from "./native-mcp-types.js"

type NativeMcpSpec = NonNullable<HarnessDefinition["nativeMcp"]>

export type NativeMcpEditor = Pick<
  NativeMcpManager,
  "listRemovals" | "removeServer" | "restoreRemoval" | "setNativeEnabled"
>

const entryFor = (
  spec: NativeMcpSpec,
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

/// The destructive native-config operations: every edit re-reads the file
/// immediately beforehand, takes a one-time backup, and writes atomically.
export const makeNativeMcpEditor = (
  config: NativeMcpManagerConfig,
  environment: NativeMcpEnvironment,
  scan: () => Promise<NativeMcpScan>
): NativeMcpEditor => {
  const { env, fs, home } = environment

  /// Catalog definition whose native config Codevisor may edit. All the
  /// destructive operations funnel through this gate.
  const writableDefinition = (
    harnessId: string
  ): { readonly definition: HarnessDefinition; readonly spec: NativeMcpSpec } => {
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
    spec: NativeMcpSpec
  ): Promise<{ readonly configPath: string; readonly content: string }> => {
    const configPath = resolveNativeConfigPath(spec.path, { env, home })
    const content = await fs.readFile(configPath)
    if (content === undefined) {
      throw new NativeMcpError(`${configPath} does not exist`, "notFound")
    }
    return { configPath, content }
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

  return { listRemovals, removeServer, restoreRemoval, setNativeEnabled }
}
