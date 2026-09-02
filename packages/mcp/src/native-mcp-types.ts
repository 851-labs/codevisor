import type {
  ImportNativeMcpsRequest,
  ImportNativeMcpsResult,
  NativeMcpRemoval,
  NativeMcpScan,
  RemoveNativeMcpResult
} from "@codevisor/api"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "./mcp-manager-types.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"

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
