import { spawn } from "node:child_process"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { gunzipSync } from "node:zlib"

import type { Skill } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SkillStore } from "@codevisor/skills"
import { freeSyncKey, treeHash, type BlobStore, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { stringField } from "../unknown-values.js"
import { openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export const SKILLS_SYNC_NAMESPACE = "codevisor-skills"
const APPLIED_NAMESPACE = "local.codevisor-skills-applied"
const MANAGED_MARKER = ".codevisor-managed-skill"

export interface SkillsSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly renamed: ReadonlyArray<SkillRename>
  readonly missingBlobs: ReadonlyArray<MissingSkillBlob>
}

export interface SkillsSyncResult {
  readonly status: SkillsSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

export interface SkillsSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly store: Pick<SkillStore, "dir" | "list" | "remove" | "rename" | "replace">
  readonly blobs: BlobStore
  readonly serverId: string
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const tarExec = (args: ReadonlyArray<string>, input?: Buffer): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    const child = spawn("tar", args, { env: { ...process.env, COPYFILE_DISABLE: "1" } })
    const chunks: Array<Buffer> = []
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk))
    child.once("error", reject)
    child.once("close", (code) =>
      code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error(`tar exited with ${code}`))
    )
    child.stdin.on("error", () => undefined)
    if (input !== undefined) child.stdin.write(input)
    child.stdin.end()
  })

/* v8 ignore next */
const MAC_METADATA_FLAGS = process.platform === "darwin" ? ["--no-mac-metadata"] : []

export const packSkillArchive = (skillPath: string): Promise<Buffer> =>
  tarExec(["-czf", "-", ...MAC_METADATA_FLAGS, "-C", skillPath, "."])

const EXCLUDED: ReadonlySet<string> = new Set([MANAGED_MARKER])

const verifiedBlobIds = new Set<string>()

export const unpackSkillArchive = async (
  bytes: Buffer
): Promise<{ readonly path: string; readonly hash: string }> => {
  const path = await mkdtemp(join(tmpdir(), "codevisor-skill-"))
  try {
    await tarExec(["-xzf", "-", "-C", path], bytes)
    return { path, hash: await treeHash(path, { exclude: EXCLUDED }) }
  } catch (error) {
    await rm(path, { recursive: true, force: true })
    throw error
  }
}

export const skillTreeHash = (path: string): Promise<string> =>
  treeHash(path, { exclude: EXCLUDED })

const entryHash = (entry: SyncEntryRecord): string | undefined =>
  entry.deleted === true ? undefined : stringField(entry.value, "hash")

export const reconcileSkills = async (deps: SkillsSyncDeps): Promise<SkillsSyncResult> => {
  const localSkills = new Map(
    (await deps.store.list()).skills.map((skill) => [skill.directoryName, skill])
  )
  const localHashes = new Map<string, string>()
  const hashedSkills: Array<HashedSkill> = []
  for (const [directoryName, skill] of localSkills) {
    const localHash = await skillTreeHash(skill.path)
    localHashes.set(directoryName, localHash)
    hashedSkills.push({ directoryName, skill, localHash })
  }
  const replica = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const ledger = openSyncLedger({ owner: deps, replica, applied: appliedEntries })

  const published: Array<string> = []
  const renamed: Array<SkillRename> = []
  for (const { directoryName, skill, localHash } of hashedSkills) {
    if (blobUnverified(deps, localHash)) {
      if (
        !deps.blobs.has(localHash) ||
        !(await verifySkillArchive(localHash, await deps.blobs.read(localHash)))
      ) {
        deps.blobs.write(localHash, await packSkillArchive(skill.path))
      }
      verifiedBlobIds.add(localHash)
    }
    if (ledger.applied.get(directoryName) === localHash) continue

    const existing = replicaByKey.get(directoryName)
    const replicaHash = existing === undefined ? undefined : entryHash(existing)
    let key = directoryName
    if (!ledger.applied.has(directoryName) && replicaHash !== undefined) {
      if (replicaHash === localHash) {
        ledger.markApplied(directoryName, () => localHash)
        continue
      }

      key = freeSyncKey(
        directoryName,
        (candidate) => localSkills.has(candidate) || replicaByKey.has(candidate)
      )
      const path = join(deps.store.dir, key)
      await deps.store.rename(directoryName, key)
      localSkills.delete(directoryName)
      localHashes.delete(directoryName)
      localSkills.set(key, { ...skill, directoryName: key, path })
      localHashes.set(key, localHash)
      renamed.push({ from: directoryName, to: key })
    }
    ledger.publish(key, { hash: localHash, name: skill.name }, () => localHash)
    published.push(key)
  }
  ledger.retractUnlisted(localSkills, replicaByKey, published)

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  if (ledger.replicaWrites.length > 0) {
    changedEntries = (
      await run(deps.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, ledger.replicaWrites))
    ).changed
  }
  const merged = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))

  const applied: Array<string> = []
  const removed: Array<string> = []
  const missingBlobs: Array<MissingSkillBlob> = []
  for (const entry of merged) {
    const directoryName = entry.key
    const wantedHash = entryHash(entry)
    const localHash = localHashes.get(directoryName)
    if (wantedHash === undefined) {
      if (!isUnchangedLocal(ledger, localSkills, directoryName, localHash)) continue

      await deps.store.remove(directoryName)
      ledger.markRemoved(directoryName)
      removed.push(directoryName)
      continue
    }

    if (holdsHash(ledger, directoryName, localHash, wantedHash)) continue
    if (!deps.blobs.has(wantedHash)) {
      missingBlobs.push({ directoryName, hash: wantedHash })
      continue
    }

    const unpacked = await unpackSkillArchive(await deps.blobs.read(wantedHash))
    try {
      if (unpacked.hash !== wantedHash) {
        deps.blobs.remove(wantedHash)
        missingBlobs.push({ directoryName, hash: wantedHash })
        continue
      }
      await deps.store.replace(directoryName, unpacked.path)
      ledger.markApplied(directoryName, () => wantedHash)
      applied.push(directoryName)
    } finally {
      await rm(unpacked.path, { recursive: true, force: true })
    }
  }

  if (ledger.appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, ledger.appliedWrites))
  }
  return {
    status: { published, applied, removed, renamed, missingBlobs },
    changedEntries
  }
}

export const archiveEntryNames = (bytes: Buffer): ReadonlyArray<string> => {
  const tar = gunzipSync(bytes)
  const names: Array<string> = []
  let offset = 0
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512)
    if (header.every((byte) => byte === 0)) break
    names.push(
      header
        .subarray(0, 100)
        .toString("utf8")
        .replace(/\0[^]*$/, "")
    )
    const size = Number.parseInt(
      header.subarray(124, 136).toString("ascii").replaceAll("\0", "").trim() || "0",
      8
    )
    offset += 512 + Math.ceil(size / 512) * 512
  }
  return names
}

const isMacMetadataJunk = (name: string): boolean => {
  const base = name.split("/").findLast(Boolean) ?? ""
  return base.startsWith("._") || base === ".DS_Store"
}

export const verifySkillArchive = async (id: string, bytes: Buffer): Promise<boolean> => {
  try {
    if (archiveEntryNames(bytes).some(isMacMetadataJunk)) return false
    const unpacked = await unpackSkillArchive(bytes)
    const matches = unpacked.hash === id
    await rm(unpacked.path, { recursive: true, force: true })
    return matches
  } catch {
    return false
  }
}

interface SkillRename {
  readonly from: string
  readonly to: string
}

interface MissingSkillBlob {
  readonly directoryName: string
  readonly hash: string
}

interface HashedSkill {
  readonly directoryName: string
  readonly skill: Skill
  readonly localHash: string
}

const blobUnverified = (deps: SkillsSyncDeps, hash: string): boolean =>
  !verifiedBlobIds.has(hash) || !deps.blobs.has(hash)

const isUnchangedLocal = (
  ledger: SyncLedger,
  localSkills: ReadonlyMap<string, Skill>,
  directoryName: string,
  localHash: string | undefined
): boolean => localSkills.has(directoryName) && ledger.applied.get(directoryName) === localHash

const holdsHash = (
  ledger: SyncLedger,
  directoryName: string,
  localHash: string | undefined,
  wantedHash: string
): boolean => wantedHash === localHash || ledger.applied.get(directoryName) === wantedHash
