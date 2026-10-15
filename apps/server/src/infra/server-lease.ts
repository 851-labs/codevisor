import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

import lockfile from "proper-lockfile"

import { field, stringField } from "../unknown-values.js"

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
    const owner: unknown = JSON.parse(readFileSync(ownerPath(databasePath), "utf8"))
    const pid = field(owner, "pid")
    const bootId = stringField(owner, "bootId")
    const holder = typeof pid === "number" ? `pid ${pid}` : "an unknown process"
    const boot = bootId === undefined ? "" : `, boot ${bootId}`
    return `${holder}${boot}`
  } catch {
    return undefined
  }
}

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
        const current: unknown = JSON.parse(readFileSync(ownerPath(databasePath), "utf8"))
        if (field(current, "bootId") === owner.bootId) {
          rmSync(ownerPath(databasePath), { force: true })
        }
      } catch {}
      await unlock()
    }
  }
}
