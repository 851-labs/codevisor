import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, readdir, rename, rm, stat, utimes } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import { pathExists } from "./files.ts"

const exec = promisify(execFile)

export const STORE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000
const incomingPrefix = ".incoming-"
const incomingRetentionMs = 24 * 60 * 60 * 1000

export async function cloneTree(source: string, destination: string): Promise<void> {
  await exec("/bin/cp", ["-c", "-R", "-p", source, destination])
}

export async function sameVolume(a: string, b: string): Promise<boolean> {
  const [first, second] = await Promise.all([stat(a), stat(b)])
  return first.dev === second.dev
}

export async function ensureStoreEntry(
  store: string,
  entry: string,
  populate: (staging: string) => Promise<unknown>,
  now = Date.now()
): Promise<string> {
  const destination = join(store, entry)
  if (await pathExists(destination)) return destination

  await mkdir(store, { recursive: true })
  const staging = join(store, `${incomingPrefix}${randomUUID()}`)
  try {
    await mkdir(staging)
    await populate(staging)
    await publish(staging, destination)
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
  await pruneStore(store, now, new Set([entry]))
  return destination
}

export async function touchStoreEntry(
  store: string,
  entry: string,
  now = Date.now()
): Promise<void> {
  const date = new Date(now)
  await utimes(join(store, entry), date, date).catch(() => {})
}

export async function pruneStore(
  store: string,
  now = Date.now(),
  keep: ReadonlySet<string> = new Set()
): Promise<Array<string>> {
  const names = await readdir(store).catch(() => undefined)
  if (names === undefined) return []

  const removed: Array<string> = []
  for (const name of names) {
    if (!(await isExpired(store, name, now, keep))) continue

    await rm(join(store, name), { recursive: true, force: true })
    removed.push(name)
  }
  return removed
}

async function publish(staging: string, destination: string): Promise<void> {
  try {
    await rename(staging, destination)
  } catch (error) {
    if (
      !(
        error instanceof Error &&
        "code" in error &&
        (error.code === "ENOTEMPTY" || error.code === "EEXIST")
      )
    )
      throw error
  }
}

async function isExpired(
  store: string,
  name: string,
  now: number,
  keep: ReadonlySet<string>
): Promise<boolean> {
  const incoming = name.startsWith(incomingPrefix)
  if (keep.has(name) || (name.startsWith(".") && !incoming)) return false

  const info = await stat(join(store, name)).catch(() => undefined)
  if (info === undefined) return false

  return now - info.mtimeMs >= (incoming ? incomingRetentionMs : STORE_RETENTION_MS)
}
