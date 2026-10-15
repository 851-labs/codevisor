import {
  McpAuthType,
  McpConnectionState,
  McpServerKind,
  McpTransport,
  type McpServer,
  type NativeMcpRemoval
} from "@codevisor/api"
import { Schema } from "effect"

import { integer, nullable, rowReader, text } from "./row-reader.js"

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

export interface NativeConfigBackupRecord {
  readonly filePath: string
  readonly backupPath: string
  readonly createdAt: string
}

export interface NativeMcpRemovalRecord extends Omit<NativeMcpRemoval, "restoredAt"> {
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

export const mcpServerRows = rowReader<McpServerRow>({
  id: text,
  name: text,
  kind: Schema.is(McpServerKind),
  transport: Schema.is(McpTransport),
  url: nullable(text),
  command: nullable(text),
  args: text,
  enabled: integer,
  auth_type: Schema.is(McpAuthType),
  oauth_scope: nullable(text),
  connection_state: Schema.is(McpConnectionState),
  tool_count: integer,
  detail: nullable(text),
  secret_cipher: nullable(text),
  created_at: text,
  updated_at: text
})

export const nativeConfigBackupRows = rowReader<NativeConfigBackupRow>({
  file_path: text,
  backup_path: text,
  created_at: text
})

export const nativeMcpRemovalRows = rowReader<NativeMcpRemovalRow>({
  id: text,
  harness_id: text,
  config_path: text,
  server_name: text,
  fragment: text,
  removed_at: text,
  restored_at: nullable(text)
})
