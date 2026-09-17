import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import {
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  rmdir,
  symlink,
  writeFile
} from "node:fs/promises"
import { dirname, join } from "node:path"

import type { ServerDataLayout } from "./data-dir.js"
import { acquireServerLease, type ServerLease } from "./server-lease.js"

const databaseName = "codevisor-server.sqlite"
const transient = new Set([
  `${databaseName}.lock`,
  `${databaseName}.server-owner.json`,
  "server-startup.json",
  "server.pid"
])

const statIfPresent = async (path: string) => {
  try {
    return await lstat(path)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined
    throw error
  }
}

const hash = async (path: string): Promise<string> => {
  const digest = createHash("sha256")
  for await (const chunk of createReadStream(path)) digest.update(chunk)
  return digest.digest("hex")
}

/// Validate the entire merge before moving anything. In particular a login
/// stranded in ~/.codevisor/data can join a database in /var/lib/codevisor,
/// but two different credentials or databases must never be silently merged.
const preflight = async (source: string, target: string): Promise<void> => {
  const destination = await statIfPresent(target)
  if (destination === undefined) return
  const origin = await lstat(source)
  if (origin.isDirectory() && destination.isDirectory()) {
    for (const name of await readdir(source)) {
      await preflight(join(source, name), join(target, name))
    }
    return
  }
  if (origin.isSymbolicLink() && destination.isSymbolicLink()) {
    if ((await readlink(source)) === (await readlink(target))) return
  } else if (origin.isFile() && destination.isFile() && origin.size === destination.size) {
    if ((await hash(source)) === (await hash(target))) return
  }
  throw new Error(
    `Cannot migrate ${source}: ${target} contains different data. Both copies were preserved.`
  )
}

/// Each cross-filesystem copy is staged before becoming visible. A retry can
/// finish after either rename or source removal, without accepting a partial
/// destination. The caller holds leases on both databases throughout.
export const moveLinuxDataEntry = async (source: string, target: string): Promise<void> => {
  const destination = await statIfPresent(target)
  if (destination !== undefined) {
    const origin = await lstat(source)
    if (origin.isDirectory() && destination.isDirectory()) {
      for (const name of await readdir(source)) {
        await moveLinuxDataEntry(join(source, name), join(target, name))
      }
      await rmdir(source)
    } else {
      await preflight(source, target)
      await rm(source)
    }
    return
  }
  try {
    await rename(source, target)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EXDEV") throw error
    const staging = `${target}.codevisor-migrating`
    await rm(staging, { recursive: true, force: true })
    await cp(source, staging, { recursive: true, preserveTimestamps: true, verbatimSymlinks: true })
    await preflight(source, staging)
    await rename(staging, target)
    await rm(source, { recursive: true })
  }
}

export const canonicalLinuxService = (text: string, source: string, target: string): string => {
  // Only the installer-owned --db argument changes; keep ports, names and
  // administrator settings. systemd treats % as a specifier, even in quotes.
  const quoted = `"${target.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%")}"`
  const escaped = source.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const argument = new RegExp(`(--db(?:=|\\s+))(?:"${escaped}"|'${escaped}'|${escaped})(?=\\s|$)`)
  return text.replace(/^ExecStart=.*$/gm, (line) =>
    line.replace(argument, (_match, flag: string) => `${flag}${quoted}`)
  )
}

interface MigrationOptions {
  readonly layout: ServerDataLayout
  readonly bootId: string
  readonly log: (message: string) => void
  readonly servicePath?: string
  readonly reloadService: () => Promise<void>
  readonly moveEntry?: typeof moveLinuxDataEntry
}

const updateService = async (options: MigrationOptions, source: string): Promise<void> => {
  const path = options.servicePath
  if (path === undefined) return
  const stat = await statIfPresent(path)
  if (stat === undefined) return
  const original = await readFile(path, "utf8")
  const updated = canonicalLinuxService(
    original,
    join(source, databaseName),
    options.layout.databasePath
  )
  if (updated === original) return
  try {
    await writeFile(`${path}.before-canonical-data`, original, {
      flag: "wx",
      mode: stat.mode & 0o777
    })
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
  }
  const temporary = `${path}.canonical-data.tmp`
  await writeFile(temporary, updated, { mode: stat.mode & 0o777 })
  await rename(temporary, path)
  try {
    await options.reloadService()
  } catch (error) {
    // The old ExecStart is also translated by resolveServerDataLayout. This
    // covers containers/chroots where a unit exists without a running systemd.
    options.log(`Updated the service data path; systemd reload was unavailable: ${String(error)}`)
  }
}

/// Runs before opening SQLite on the first updated Linux root startup. Both
/// old and new launches converge on the canonical path. The small journal
/// permits interrupted moves to resume, and the legacy alias preserves stored
/// absolute attachment paths and older launchers without a second data store.
export const migrateLinuxDataLayout = async (options: MigrationOptions): Promise<void> => {
  const source = options.layout.legacyDataDirectory
  if (source === undefined) return
  const target = dirname(options.layout.databasePath)
  const journalPath = join(dirname(target), "linux-data-migration.json")
  const journal = JSON.stringify({ version: 1, source, target })
  const sourceStat = await statIfPresent(source)
  if (sourceStat === undefined && (await statIfPresent(journalPath)) === undefined) {
    await updateService(options, source)
    return
  }
  const guard = await acquireServerLease(join(dirname(target), "linux-data-migration"), {
    bootId: options.bootId,
    appOwned: false,
    waitForOwnership: true
  })
  const leases: ServerLease[] = []
  try {
    const sourceStat = await statIfPresent(source)
    if (sourceStat === undefined) {
      // A process can stop between removing the emptied legacy directory and
      // installing its compatibility alias. Finish that final step on retry.
      if (
        (await statIfPresent(journalPath)) !== undefined &&
        (await readFile(journalPath, "utf8")) === journal
      ) {
        await symlink(target, source, "dir")
        await rm(journalPath)
      }
      await updateService(options, source)
      return
    }
    if (sourceStat.isSymbolicLink()) {
      if ((await realpath(source)) !== (await realpath(target))) {
        throw new Error(`Cannot migrate unexpected legacy data symlink: ${source}`)
      }
      await updateService(options, source)
      await rm(journalPath, { force: true })
      return
    }
    leases.push(
      await acquireServerLease(join(source, databaseName), {
        bootId: options.bootId,
        appOwned: false,
        waitForOwnership: true
      })
    )
    const targetStat = await statIfPresent(target)
    if (targetStat?.isSymbolicLink()) {
      if ((await realpath(target)) !== (await realpath(source))) {
        throw new Error(`Cannot migrate into a custom data symlink: ${target}`)
      }
      // Recover the workaround used by older installs: make the canonical
      // location the real directory, then leave only the legacy alias.
      await rm(target)
    }
    await mkdir(target, { recursive: true })
    leases.push(
      await acquireServerLease(options.layout.databasePath, {
        bootId: options.bootId,
        appOwned: false,
        waitForOwnership: true
      })
    )
    const previous = await statIfPresent(journalPath)
    const resuming = previous !== undefined && (await readFile(journalPath, "utf8")) === journal
    if (
      !resuming &&
      (await statIfPresent(join(source, databaseName))) &&
      (await statIfPresent(options.layout.databasePath))
    ) {
      throw new Error(
        `Both ${source} and ${target} contain a database. Both copies were preserved; choose which installation to keep before upgrading.`
      )
    }
    const entries = (await readdir(source)).filter((name) => !transient.has(name))
    for (const name of entries) await preflight(join(source, name), join(target, name))
    await writeFile(`${journalPath}.tmp`, journal, { mode: 0o600 })
    await rename(`${journalPath}.tmp`, journalPath)
    options.log(`Migrating Codevisor data from ${source} to ${target}`)
    for (const name of entries) {
      await (options.moveEntry ?? moveLinuxDataEntry)(join(source, name), join(target, name))
    }
    await rm(join(source, "server-startup.json"), { force: true })
    await rm(join(source, "server.pid"), { force: true })
    for (const lease of leases.splice(0).reverse()) await lease.release()
    await rmdir(source)
    await symlink(target, source, "dir")
    await rm(journalPath)
    await updateService(options, source)
    options.log(`Codevisor data migration complete: ${target}`)
  } finally {
    for (const lease of leases.reverse()) await lease.release()
    await guard.release()
  }
}
