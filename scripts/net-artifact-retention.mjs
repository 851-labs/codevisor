import { readdir, rm, stat, utimes } from "node:fs/promises"
import { join } from "node:path"

const NET_STAMPS_KEPT = 4

const stampName = /^[0-9a-f]{16}$/

export async function retainNetStamp(root, stamp, now = Date.now()) {
  await markUsed(join(root, stamp), now)
  const unused = (await stampsByRecentUse(root)).filter((entry) => entry.name !== stamp)
  const evicted = unused.slice(NET_STAMPS_KEPT - 1)
  await Promise.all(evicted.map((entry) => rm(entry.path, { recursive: true, force: true })))
  return evicted.map((entry) => entry.name)
}

async function markUsed(path, now) {
  const date = new Date(now)
  await utimes(path, date, date)
}

async function stampsByRecentUse(root) {
  const names = (await readdir(root)).filter((name) => stampName.test(name))
  const entries = await Promise.all(names.map((name) => stampEntry(root, name)))
  return entries
    .filter((entry) => entry !== undefined)
    .toSorted((a, b) => b.lastUsedMs - a.lastUsedMs)
}

async function stampEntry(root, name) {
  const path = join(root, name)
  const info = await stat(path).catch(() => undefined)
  if (!info?.isDirectory()) return undefined

  return { name, path, lastUsedMs: info.mtimeMs }
}
