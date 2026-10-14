import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type {
  ImportNativeMcpsRequest,
  ImportNativeMcpsResult,
  NativeMcpRemoval,
  NativeMcpScan,
  RemoveNativeMcpResult
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import type { McpManager } from "./mcp-manager-types.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"

export interface NativeMcpManager {
  readonly scan: () => Promise<NativeMcpScan>
  readonly importServers: (request: ImportNativeMcpsRequest) => Promise<ImportNativeMcpsResult>
  readonly removeServer: (harnessId: string, serverName: string) => Promise<RemoveNativeMcpResult>
  readonly listRemovals: () => Promise<ReadonlyArray<NativeMcpRemoval>>
  readonly restoreRemoval: (id: string) => Promise<NativeMcpScan>
  readonly setNativeEnabled: (
    harnessId: string,
    serverName: string,
    enabled: boolean
  ) => Promise<NativeMcpScan>
}

export class NativeMcpError extends Error {
  constructor(
    message: string,
    readonly code: "notFound" | "conflict" | "unsupported"
  ) {
    super(message)
    this.name = "NativeMcpError"
  }
}

export type ImportTargetMcpManager = Pick<McpManager, "create" | "detectAuth">

export interface NativeMcpManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  readonly mcp: ImportTargetMcpManager
  readonly dataDir: string
  readonly homedir: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly fs: NativeConfigFileSystem
}
