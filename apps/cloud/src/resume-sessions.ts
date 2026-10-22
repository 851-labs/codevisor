import { toBase64Url } from "@codevisor/cloud-crypto"

import { sha256Hex } from "./tokens.js"
export const DEFAULT_RESUME_GRACE_MS = 60_000

export const RESUME_BUFFER_CAP_BYTES = 256 * 1024

export interface ResumeSessionRow extends Record<string, SqlStorageValue> {
  connection_id: string
  kind: string
  device_id: string
  public_key: string | null
  resume_token_hash: string
  expires_at: number | null
}

export class ResumeSessions {
  constructor(
    private readonly sql: SqlStorage,
    private readonly graceMs: number
  ) {}

  async register(
    connectionId: string,
    kind: "app" | "machine",
    deviceId: string,
    publicKey: string | undefined
  ): Promise<string> {
    const token = toBase64Url(crypto.getRandomValues(new Uint8Array(32)))
    const hash = await sha256Hex(token)
    this.sql.exec(sessionSql.upsert, connectionId, kind, deviceId, publicKey ?? null, hash)
    return token
  }

  async adoptOrRegister(
    connectionId: string,
    kind: "app" | "machine",
    device: { deviceId: string; publicKey: string },
    resumeToken: string | undefined
  ): Promise<{ connectionId: string; token: string; resumed: boolean }> {
    if (resumeToken !== undefined) {
      const session = await this.tryResume(kind, resumeToken, Date.now())
      if (session !== undefined && session.device_id === device.deviceId) {
        const token = toBase64Url(crypto.getRandomValues(new Uint8Array(32)))
        const hash = await sha256Hex(token)
        const claimed = this.sql
          .exec<ResumeSessionRow>(
            sessionSql.claim,
            hash,
            device.publicKey,
            session.connection_id,
            session.resume_token_hash,
            kind,
            device.deviceId,
            Date.now()
          )
          .toArray()[0]
        if (claimed !== undefined)
          return { connectionId: session.connection_id, token, resumed: true }
      }
    }
    const token = await this.register(connectionId, kind, device.deviceId, device.publicKey)
    return { connectionId, token, resumed: false }
  }

  async tryResume(kind: "app" | "machine", token: string, now: number) {
    const hash = await sha256Hex(token)
    const row = sessionByToken(this.sql, hash, kind)
    if (row === undefined) return undefined
    if (row.expires_at !== null && row.expires_at <= now) return undefined
    return row
  }

  markDisconnected(connectionId: string, now: number): number | undefined {
    const deadline = now + this.graceMs
    const updated = this.sql.exec(sessionSql.expire, deadline, connectionId).rowsWritten
    if (updated > 0) return deadline
    const existing = sessionById(this.sql, connectionId)
    return existing?.expires_at ?? undefined
  }

  delete(connectionId: string): void {
    this.sql.exec(sessionSql.delete, connectionId)
    this.sql.exec(bufferSql.delete, connectionId)
  }

  deleteForMachineDevice(deviceId: string, keep?: string): string[] {
    const rows = machineSessionIds(this.sql, deviceId)
    const deleted: string[] = []
    for (const row of rows) {
      if (row.connection_id === keep) continue
      this.delete(row.connection_id)
      deleted.push(row.connection_id)
    }
    return deleted
  }

  expired(now: number): ResumeSessionRow[] {
    return this.sql.exec<ResumeSessionRow>(sessionSql.expired, now).toArray()
  }

  nextExpiry(): number | undefined {
    const row = this.sql
      .exec<{ next: number | null } & Record<string, SqlStorageValue>>(sessionSql.nextExpiry)
      .toArray()[0]
    return row?.next ?? undefined
  }

  machineDeviceIdsInGrace(now: number): Set<string> {
    return new Set(
      this.sql
        .exec<ResumeSessionRow>(sessionSql.machineDevicesInGrace, now)
        .toArray()
        .map((row) => row.device_id)
    )
  }

  machineGraceSession(deviceId: string, now: number): ResumeSessionRow | undefined {
    return this.sql.exec<ResumeSessionRow>(sessionSql.machineGrace, deviceId, now).toArray()[0]
  }

  openerGraceSession(peerId: string, now: number): ResumeSessionRow | undefined {
    return this.sql.exec<ResumeSessionRow>(sessionSql.openerGrace, peerId, now).toArray()[0]
  }

  buffer(connectionId: string, message: Uint8Array): boolean {
    if (bufferedBytes(this.sql, connectionId) + message.byteLength > RESUME_BUFFER_CAP_BYTES) {
      return false
    }

    const seq = lastBufferSeq(this.sql, connectionId) + 1
    this.sql.exec(bufferSql.insert, connectionId, seq, new Uint8Array(message).buffer)
    return true
  }

  drainBuffers(connectionId: string): Uint8Array[] {
    const rows = bufferedMessages(this.sql, connectionId)
    this.sql.exec(bufferSql.delete, connectionId)
    return rows.map((row) => new Uint8Array(row.message))
  }
}

const sessionByToken = (sql: SqlStorage, hash: string, kind: string) =>
  sql.exec<ResumeSessionRow>(sessionSql.byToken, hash, kind).toArray()[0]

const sessionById = (sql: SqlStorage, connectionId: string) =>
  sql.exec<ResumeSessionRow>(sessionSql.byId, connectionId).toArray()[0]

const machineSessionIds = (sql: SqlStorage, deviceId: string) =>
  sql.exec<ResumeSessionRow>(sessionSql.machineConnectionIds, deviceId).toArray()

const bufferedBytes = (sql: SqlStorage, connectionId: string): number =>
  sql
    .exec<{ total: number | null } & Record<string, SqlStorageValue>>(
      bufferSql.totalBytes,
      connectionId
    )
    .toArray()[0]?.total ?? 0

const lastBufferSeq = (sql: SqlStorage, connectionId: string): number =>
  sql
    .exec<{ next: number | null } & Record<string, SqlStorageValue>>(
      bufferSql.lastSeq,
      connectionId
    )
    .toArray()[0]?.next ?? 0

const bufferedMessages = (sql: SqlStorage, connectionId: string) =>
  sql
    .exec<{ message: ArrayBuffer } & Record<string, SqlStorageValue>>(
      bufferSql.messages,
      connectionId
    )
    .toArray()

const sessionSql = {
  upsert: `INSERT INTO sessions (connection_id, kind, device_id, public_key, resume_token_hash, expires_at)
       VALUES (?, ?, ?, ?, ?, NULL)
       ON CONFLICT(connection_id) DO UPDATE SET
         kind = excluded.kind,
         device_id = excluded.device_id,
         public_key = excluded.public_key,
         resume_token_hash = excluded.resume_token_hash,
         expires_at = NULL`,
  claim: `UPDATE sessions SET resume_token_hash = ?, public_key = ?, expires_at = NULL
           WHERE connection_id = ? AND resume_token_hash = ? AND kind = ? AND device_id = ?
             AND (expires_at IS NULL OR expires_at > ?)
           RETURNING *`,
  byToken: "SELECT * FROM sessions WHERE resume_token_hash = ? AND kind = ?",
  byId: "SELECT * FROM sessions WHERE connection_id = ?",
  expire: "UPDATE sessions SET expires_at = ? WHERE connection_id = ? AND expires_at IS NULL",
  delete: "DELETE FROM sessions WHERE connection_id = ?",
  machineConnectionIds:
    "SELECT connection_id FROM sessions WHERE kind = 'machine' AND device_id = ?",
  expired: "SELECT * FROM sessions WHERE expires_at IS NOT NULL AND expires_at <= ?",
  nextExpiry: "SELECT MIN(expires_at) AS next FROM sessions WHERE expires_at IS NOT NULL",
  machineDevicesInGrace:
    "SELECT device_id FROM sessions WHERE kind = 'machine' AND expires_at IS NOT NULL AND expires_at > ?",
  machineGrace: `SELECT * FROM sessions
         WHERE kind = 'machine' AND device_id = ? AND expires_at IS NOT NULL AND expires_at > ?
         ORDER BY expires_at DESC`,
  openerGrace: `SELECT * FROM sessions
         WHERE connection_id = ? AND expires_at IS NOT NULL AND expires_at > ?`
}

const bufferSql = {
  totalBytes: "SELECT SUM(LENGTH(message)) AS total FROM session_buffers WHERE connection_id = ?",
  lastSeq: "SELECT MAX(seq) AS next FROM session_buffers WHERE connection_id = ?",
  insert: "INSERT INTO session_buffers (connection_id, seq, message) VALUES (?, ?, ?)",
  messages: "SELECT message FROM session_buffers WHERE connection_id = ? ORDER BY seq",
  delete: "DELETE FROM session_buffers WHERE connection_id = ?"
}
