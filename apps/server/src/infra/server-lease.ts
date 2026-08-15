import lockfile from "proper-lockfile"
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

export interface ServerLeaseOwner {
  readonly bootId: string
  readonly pid: number
  readonly databasePath: string
  readonly appOwned: boolean
  readonly startedAt: string
}

export interface ServerLease {
  readonly owner: ServerLeaseOwner
  readonly release: () => Promise<void>
}

const ownerPath = (databasePath: string): string => `${databasePath}.server-owner.json`

const ownerDescription = (databasePath: string): string | undefined => {
  try {
    const owner = JSON.parse(
      readFileSync(ownerPath(databasePath), "utf8")
    ) as Partial<ServerLeaseOwner>
    const pid = typeof owner.pid === "number" ? `pid ${owner.pid}` : "an unknown process"
    const boot = typeof owner.bootId === "string" ? `, boot ${owner.bootId}` : ""
    return `${pid}${boot}`
  } catch {
    return undefined
  }
}

/// Holds an operating-system-backed, heartbeat-updated lease for one database.
/// `proper-lockfile` uses an atomic lock directory and removes it on normal
/// process exit. A killed process leaves a stale lease that expires instead of
/// allowing two migration writers to race against the same SQLite database.
export const acquireServerLease = async (
  databasePath: string,
  options: {
    readonly bootId: string
    readonly appOwned: boolean
    readonly waitForOwnership?: boolean
    readonly pid?: number
    readonly now?: () => Date
  }
): Promise<ServerLease> => {
  mkdirSync(dirname(databasePath), { recursive: true })
  const owner: ServerLeaseOwner = {
    bootId: options.bootId,
    pid: options.pid ?? process.pid,
    databasePath,
    appOwned: options.appOwned,
    startedAt: (options.now?.() ?? new Date()).toISOString()
  }

  let unlock: (() => Promise<void>) | undefined
  try {
    unlock = await lockfile.lock(databasePath, {
      realpath: false,
      // A replacement app may start immediately after a crashed predecessor.
      // Give its owner monitor / stale heartbeat time to relinquish the lease.
      // Standalone servers still reject duplicate starts immediately.
      retries:
        options.waitForOwnership === true
          ? { retries: 70, factor: 1, minTimeout: 100, maxTimeout: 250, randomize: true }
          : 0,
      stale: 5_000,
      update: 1_000
    })
  } catch (cause) {
    const current = ownerDescription(databasePath)
    const detail = current === undefined ? "" : ` (${current})`
    throw new Error(`Another Codevisor server owns ${databasePath}${detail}`, { cause })
  }

  writeFileSync(ownerPath(databasePath), `${JSON.stringify(owner, undefined, 2)}\n`, "utf8")
  let released = false
  return {
    owner,
    release: async () => {
      if (released) return
      released = true
      try {
        const current = JSON.parse(
          readFileSync(ownerPath(databasePath), "utf8")
        ) as Partial<ServerLeaseOwner>
        if (current.bootId === owner.bootId) rmSync(ownerPath(databasePath), { force: true })
      } catch {
        // Diagnostics metadata is best-effort; the lock remains authoritative.
      }
      await unlock()
    }
  }
}
