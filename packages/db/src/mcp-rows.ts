import type {
  McpAuthType,
  McpConnectionState,
  McpServer,
  McpServerKind,
  McpTransport,
  NativeMcpRemoval
} from "@codevisor/api"

export interface McpServerRow {
  readonly id: string
  readonly name: string
  readonly kind: McpServerKind
  readonly transport: McpTransport
  readonly url: string | null
  readonly command: string | null
  readonly args: string
  readonly enabled: number
  readonly auth_type: McpAuthType
  readonly oauth_scope: string | null
  readonly connection_state: McpConnectionState
  readonly tool_count: number
  readonly detail: string | null
  readonly secret_cipher: string | null
  readonly created_at: string
  readonly updated_at: string
}

export interface McpServerRecord extends McpServer {
  readonly secretCipher?: string
}

/// One-time backup of a harness config file, taken before Codevisor's first
/// ever mutation of it and never overwritten afterwards.
export interface NativeConfigBackupRecord {
  readonly filePath: string
  readonly backupPath: string
  readonly createdAt: string
}

/// A parked native MCP removal; `fragment` is the verbatim parsed entry
/// (JSON-encoded) so restore can reinsert exactly what was removed.
export interface NativeMcpRemovalRecord extends NativeMcpRemoval {
  readonly fragment: string
}

export interface SaveNativeMcpRemovalRequest {
  readonly harnessId: string
  readonly configPath: string
  readonly serverName: string
  readonly fragment: string
}

export interface SaveMcpServerRecordRequest {
  readonly id?: string
  readonly name: string
  readonly kind?: McpServerKind
  readonly transport: McpTransport
  readonly url?: string
  readonly command?: string
  readonly args?: ReadonlyArray<string>
  readonly enabled: boolean
  readonly authType: McpAuthType
  readonly oauthScope?: string
  readonly connectionState: McpConnectionState
  readonly toolCount: number
  readonly detail?: string
  readonly secretCipher?: string
}

export interface NativeConfigBackupRow {
  readonly file_path: string
  readonly backup_path: string
  readonly created_at: string
}

export interface NativeMcpRemovalRow {
  readonly id: string
  readonly harness_id: string
  readonly config_path: string
  readonly server_name: string
  readonly fragment: string
  readonly removed_at: string
  readonly restored_at: string | null
}
