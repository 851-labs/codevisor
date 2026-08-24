/// Session resume for the hub — the mosh idea applied to the relay: a
/// connection's identity (its connectionId, which is also the peerId machines
/// route by) survives socket churn. On disconnect a session enters a grace
/// window instead of announcing death; frames addressed to it are buffered
/// (bounded); a reconnect presenting the session's resume token adopts the
/// old identity and replays the buffer, so channels on both peers never
/// notice a subway blip or a worker deploy. Grace expiry degrades to exactly
/// the old behavior (peer-gone / machine-offline + cursor replay).
///
/// Everything durable lives in the DO's SQLite (never socket attachments,
/// which die with their socket — surviving deploys is the point). The resume
/// token is 32 random bytes (base64url), rotated on every welcome; only its
/// SHA-256 is stored. Its format is frozen independently of the protocol
/// version: it must parse across deploy boundaries.

export const DEFAULT_RESUME_GRACE_MS = 60_000

/// Total buffered relay bytes per disconnected session. Overflow abandons the
/// session (frames already dropped → seq gaps would kill the channels anyway)
/// and falls back to the immediate-teardown path.
export const RESUME_BUFFER_CAP_BYTES = 256 * 1024

export interface ResumeSessionRow extends Record<string, SqlStorageValue> {
  connection_id: string
  kind: string
  device_id: string
  public_key: string | null
  resume_token_hash: string
  /// NULL while connected; ms epoch deadline while in the grace window.
  expires_at: number | null
}

const encodeToken = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "")

const sha256Hex = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

export class ResumeSessions {
  constructor(
    private readonly sql: SqlStorage,
    private readonly graceMs: number
  ) {}

  /// Registers (or refreshes) the session for a freshly welcomed connection
  /// and returns its new resume token. Rotated on every welcome so a token
  /// only ever resumes the connection generation it was issued to.
  async register(
    connectionId: string,
    kind: "app" | "machine",
    deviceId: string,
    publicKey: string | undefined
  ): Promise<string> {
    const token = encodeToken(crypto.getRandomValues(new Uint8Array(32)))
    const hash = await sha256Hex(token)
    this.sql.exec(
      `INSERT INTO sessions (connection_id, kind, device_id, public_key, resume_token_hash, expires_at)
       VALUES (?, ?, ?, ?, ?, NULL)
       ON CONFLICT(connection_id) DO UPDATE SET
         kind = excluded.kind,
         device_id = excluded.device_id,
         public_key = excluded.public_key,
         resume_token_hash = excluded.resume_token_hash,
         expires_at = NULL`,
      connectionId,
      kind,
      deviceId,
      publicKey ?? null,
      hash
    )
    return token
  }

  /// Adopts a resumable session's identity when the hello carries a valid
  /// token (the caller supersedes any half-open zombie socket still holding
  /// it), or registers a fresh session under `connectionId`. Returns the
  /// (possibly restored) connection id, the rotated token, and whether the
  /// identity carried over.
  async adoptOrRegister(
    connectionId: string,
    kind: "app" | "machine",
    device: { deviceId: string; publicKey: string },
    resumeToken: string | undefined,
    supersede: (adoptedConnectionId: string) => void
  ): Promise<{ connectionId: string; token: string; resumed: boolean }> {
    if (resumeToken !== undefined) {
      const session = await this.tryResume(kind, resumeToken, Date.now())
      if (session !== undefined && session.device_id === device.deviceId) {
        supersede(session.connection_id)
        const token = await this.register(
          session.connection_id,
          kind,
          device.deviceId,
          device.publicKey
        )
        return { connectionId: session.connection_id, token, resumed: true }
      }
    }
    const token = await this.register(connectionId, kind, device.deviceId, device.publicKey)
    return { connectionId, token, resumed: false }
  }

  /// Looks up a resumable session for a presented token. Resumable = same
  /// kind, and either still marked connected (the old socket is a half-open
  /// zombie the caller supersedes) or within its grace window.
  async tryResume(kind: "app" | "machine", token: string, now: number) {
    const hash = await sha256Hex(token)
    const row = this.sql
      .exec<ResumeSessionRow>(
        "SELECT * FROM sessions WHERE resume_token_hash = ? AND kind = ?",
        hash,
        kind
      )
      .toArray()[0]
    if (row === undefined) return undefined
    if (row.expires_at !== null && row.expires_at <= now) return undefined
    return row
  }

  /// Starts the grace window for a disconnected connection; returns the
  /// deadline (undefined when the connection has no session).
  markDisconnected(connectionId: string, now: number): number | undefined {
    const deadline = now + this.graceMs
    const updated = this.sql.exec(
      "UPDATE sessions SET expires_at = ? WHERE connection_id = ? AND expires_at IS NULL",
      deadline,
      connectionId
    ).rowsWritten
    return updated > 0 ? deadline : undefined
  }

  delete(connectionId: string): void {
    this.sql.exec("DELETE FROM sessions WHERE connection_id = ?", connectionId)
    this.sql.exec("DELETE FROM session_buffers WHERE connection_id = ?", connectionId)
  }

  /// Drops every session for a machine device (except `keep`, the connection
  /// doing a fresh hello) — a machine restart or account-level removal makes
  /// their grace state moot.
  deleteForMachineDevice(deviceId: string, keep?: string): void {
    const rows = this.sql
      .exec<ResumeSessionRow>(
        "SELECT connection_id FROM sessions WHERE kind = 'machine' AND device_id = ?",
        deviceId
      )
      .toArray()
    for (const row of rows) {
      if (row.connection_id !== keep) this.delete(row.connection_id)
    }
  }

  /// Sessions whose grace expired: the deferred death notices are due.
  expired(now: number): ResumeSessionRow[] {
    return this.sql
      .exec<ResumeSessionRow>(
        "SELECT * FROM sessions WHERE expires_at IS NOT NULL AND expires_at <= ?",
        now
      )
      .toArray()
  }

  /// The next pending grace deadline, for alarm scheduling.
  nextExpiry(): number | undefined {
    const row = this.sql
      .exec<
        { next: number | null } & Record<string, SqlStorageValue>
      >("SELECT MIN(expires_at) AS next FROM sessions WHERE expires_at IS NOT NULL")
      .toArray()[0]
    return row?.next ?? undefined
  }

  /// Machine device ids currently in grace — counted as online: their
  /// disconnect has not been announced, and resume would make it moot.
  machineDeviceIdsInGrace(now: number): Set<string> {
    return new Set(
      this.sql
        .exec<ResumeSessionRow>(
          "SELECT device_id FROM sessions WHERE kind = 'machine' AND expires_at IS NOT NULL AND expires_at > ?",
          now
        )
        .toArray()
        .map((row) => row.device_id)
    )
  }

  /// The in-grace session for a machine device (routing buffers under it).
  machineGraceSession(deviceId: string, now: number): ResumeSessionRow | undefined {
    return this.sql
      .exec<ResumeSessionRow>(
        `SELECT * FROM sessions
         WHERE kind = 'machine' AND device_id = ? AND expires_at IS NOT NULL AND expires_at > ?
         ORDER BY expires_at DESC`,
        deviceId,
        now
      )
      .toArray()[0]
  }

  /// The in-grace session for an app connection id.
  appGraceSession(peerId: string, now: number): ResumeSessionRow | undefined {
    return this.sql
      .exec<ResumeSessionRow>(
        `SELECT * FROM sessions
         WHERE kind = 'app' AND connection_id = ? AND expires_at IS NOT NULL AND expires_at > ?`,
        peerId,
        now
      )
      .toArray()[0]
  }

  /// Buffers one relay message for a disconnected session. False = the cap
  /// was hit: frames are being dropped, so resume can no longer be seamless —
  /// the caller abandons the session and reports the peer gone/offline.
  buffer(connectionId: string, message: Uint8Array): boolean {
    const used = this.sql
      .exec<
        { total: number | null } & Record<string, SqlStorageValue>
      >("SELECT SUM(LENGTH(message)) AS total FROM session_buffers WHERE connection_id = ?", connectionId)
      .toArray()[0]
    if ((used?.total ?? 0) + message.byteLength > RESUME_BUFFER_CAP_BYTES) return false
    const next = this.sql
      .exec<
        { next: number | null } & Record<string, SqlStorageValue>
      >("SELECT MAX(seq) AS next FROM session_buffers WHERE connection_id = ?", connectionId)
      .toArray()[0]
    this.sql.exec(
      "INSERT INTO session_buffers (connection_id, seq, message) VALUES (?, ?, ?)",
      connectionId,
      (next?.next ?? 0) + 1,
      // Copy: a subarray view would serialize its whole backing buffer.
      new Uint8Array(message).buffer
    )
    return true
  }

  /// Removes and returns the buffered messages for a resumed session, in
  /// arrival order.
  drainBuffers(connectionId: string): Uint8Array[] {
    const rows = this.sql
      .exec<
        { message: ArrayBuffer } & Record<string, SqlStorageValue>
      >("SELECT message FROM session_buffers WHERE connection_id = ? ORDER BY seq", connectionId)
      .toArray()
    this.sql.exec("DELETE FROM session_buffers WHERE connection_id = ?", connectionId)
    return rows.map((row) => new Uint8Array(row.message))
  }
}
