import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, readdir, rename, rm, stat, utimes } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

const exec = promisify(execFile)

export const STORE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000
const INCOMING_PREFIX = ".incoming-"
const INCOMING_RETENTION_MS = 24 * 60 * 60 * 1000

export async function cloneTree(source, destination) {
  await exec("/bin/cp", ["-c", "-R", "-p", source, destination])
}

export async function sameVolume(a, b) {
  const [first, second] = await Promise.all([stat(a), stat(b)])
  return first.dev === second.dev
}

export async function ensureStoreEntry(store, entry, populate, now = Date.now()) {
  const destination = join(store, entry)
  if (await exists(destination)) return destination
  await mkdir(store, { recursive: true })
  const staging = join(store, `${INCOMING_PREFIX}${randomUUID()}`)
  try {
    await mkdir(staging)
    await populate(staging)
    try {
      await rename(staging, destination)
    } catch (error) {
      if (!["ENOTEMPTY", "EEXIST"].includes(error.code)) throw error
    }
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
  await pruneStore(store, now, new Set([entry]))
  return destination
}

export async function touchStoreEntry(store, entry, now = Date.now()) {
  const date = new Date(now)
  await utimes(join(store, entry), date, date).catch(() => {})
}

export async function pruneStore(store, now = Date.now(), keep = new Set()) {
  let names
  try {
    names = await readdir(store)
  } catch {
    return []
  }
  const removed = []
  for (const name of names) {
    const incoming = name.startsWith(INCOMING_PREFIX)
    if (keep.has(name) || (name.startsWith(".") && !incoming)) continue
    const path = join(store, name)
    const info = await stat(path).catch(() => undefined)
    if (info === undefined) continue
    const retention = incoming ? INCOMING_RETENTION_MS : STORE_RETENTION_MS
    if (now - info.mtimeMs < retention) continue
    await rm(path, { recursive: true, force: true })
    removed.push(name)
  }
  return removed
}

export async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}
