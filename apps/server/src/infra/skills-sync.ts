import { spawn } from "node:child_process"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { gunzipSync } from "node:zlib"

import type { Skill } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SkillStore } from "@codevisor/skills"
import {
  freeSyncKey,
  latestSyncTimestamp,
  nextSyncTimestamp,
  treeHash,
  type BlobStore,
  type SyncEntryRecord
} from "@codevisor/sync"
import { Effect } from "effect"

import { stringField } from "../unknown-values.js"
import { appliedValuesByKey } from "./applied-values.js"

export const SKILLS_SYNC_NAMESPACE = "codevisor-skills"
const APPLIED_NAMESPACE = "local.codevisor-skills-applied"
const MANAGED_MARKER = ".codevisor-managed-skill"

export interface SkillsSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly renamed: ReadonlyArray<{ readonly from: string; readonly to: string }>
  readonly missingBlobs: ReadonlyArray<{
    readonly directoryName: string
    readonly hash: string
  }>
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
  const hashedSkills: Array<{
    readonly directoryName: string
    readonly skill: Skill
    readonly localHash: string
  }> = []
  for (const [directoryName, skill] of localSkills) {
    const localHash = await skillTreeHash(skill.path)
    localHashes.set(directoryName, localHash)
    hashedSkills.push({ directoryName, skill, localHash })
  }
  const replica = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const appliedByKey = appliedValuesByKey(appliedEntries)

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const renamed: Array<{ from: string; to: string }> = []
  const missingBlobs: Array<{ directoryName: string; hash: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncEntryRecord["timestamp"] => {
    clock = nextSyncTimestamp(deps.serverId, clock, Date.now())
    return clock
  }

  for (const { directoryName, skill, localHash } of hashedSkills) {
    if (!verifiedBlobIds.has(localHash) || !deps.blobs.has(localHash)) {
      if (
        !deps.blobs.has(localHash) ||
        !(await verifySkillArchive(localHash, await deps.blobs.read(localHash)))
      ) {
        deps.blobs.write(localHash, await packSkillArchive(skill.path))
      }
      verifiedBlobIds.add(localHash)
    }
    if (appliedByKey.get(directoryName) === localHash) continue
    let key = directoryName
    let path = skill.path
    const existing = replicaByKey.get(directoryName)
    const replicaHash = existing === undefined ? undefined : entryHash(existing)
    if (!appliedByKey.has(directoryName) && replicaHash !== undefined) {
      if (replicaHash === localHash) {
        appliedWrites.push({ key: directoryName, value: localHash, timestamp: stamp() })
        appliedByKey.set(directoryName, localHash)
        continue
      }
      key = freeSyncKey(
        directoryName,
        (candidate) => localSkills.has(candidate) || replicaByKey.has(candidate)
      )
      path = join(deps.store.dir, key)
      await deps.store.rename(directoryName, key)
      localSkills.delete(directoryName)
      localHashes.delete(directoryName)
      localSkills.set(key, { ...skill, directoryName: key, path })
      localHashes.set(key, localHash)
      renamed.push({ from: directoryName, to: key })
    }
    replicaWrites.push({
      key,
      value: { hash: localHash, name: skill.name },
      timestamp: stamp()
    })
    appliedWrites.push({ key, value: localHash, timestamp: stamp() })
    appliedByKey.set(key, localHash)
    published.push(key)
  }

  for (const [directoryName] of appliedByKey) {
    if (localSkills.has(directoryName)) continue
    if (replicaByKey.get(directoryName)?.deleted === true) continue
    replicaWrites.push({ key: directoryName, value: null, deleted: true, timestamp: stamp() })
    appliedWrites.push({ key: directoryName, value: null, deleted: true, timestamp: stamp() })
    published.push(directoryName)
  }

  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))

  for (const entry of merged) {
    const directoryName = entry.key
    const wantedHash = entryHash(entry)
    const localHash = localHashes.get(directoryName)
    if (wantedHash === undefined) {
      if (localSkills.has(directoryName) && appliedByKey.get(directoryName) === localHash) {
        await deps.store.remove(directoryName)
        appliedWrites.push({ key: directoryName, value: null, deleted: true, timestamp: stamp() })
        appliedByKey.delete(directoryName)
        removed.push(directoryName)
      }
      continue
    }
    if (wantedHash === localHash || appliedByKey.get(directoryName) === wantedHash) continue
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
      appliedWrites.push({ key: directoryName, value: wantedHash, timestamp: stamp() })
      appliedByKey.set(directoryName, wantedHash)
      applied.push(directoryName)
    } finally {
      await rm(unpacked.path, { recursive: true, force: true })
    }
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, appliedWrites))
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
