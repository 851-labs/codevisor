import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SkillsManager } from "@codevisor/skills"
import {
  freeSyncKey,
  latestSyncTimestamp,
  nextSyncTimestamp,
  treeHash,
  type BlobStore,
  type SyncEntryRecord
} from "@codevisor/sync"
import { Effect } from "effect"
import { spawn } from "node:child_process"
import { cp, mkdtemp, rename, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

/// Server half of skills replication. The "skills" sync namespace is the
/// fleet's desired state — one entry per canonical skill, valued
/// { hash, name } where hash is the TREE hash of the skill directory — and
/// the blob store carries the bytes. This module reconciles the local
/// canonical store against the replica in the classic three-way shape:
/// the private "local.skills-applied" namespace (dot-named, so the HTTP
/// validator can never expose or gossip it) records what this machine last
/// published or applied, which is how a local edit is told apart from a
/// replica this machine simply hasn't caught up to. Clients ferry missing
/// blobs between machines; this module never dials anyone.
export const SKILLS_SYNC_NAMESPACE = "skills"
const APPLIED_NAMESPACE = "local.skills-applied"
const MANAGED_MARKER = ".codevisor-managed-skill"

export interface SkillsSyncStatus {
  /// Local skills (new or edited) published to the replica this pass.
  readonly published: ReadonlyArray<string>
  /// Replica skills unpacked into the canonical store this pass.
  readonly applied: ReadonlyArray<string>
  /// Local skills removed because a newer tombstone won.
  readonly removed: ReadonlyArray<string>
  /// First-contact collisions: a never-synced local skill whose name the
  /// replica already held with different content moved aside to `to`.
  readonly renamed: ReadonlyArray<{ readonly from: string; readonly to: string }>
  /// Replica entries this machine cannot apply until a client ferries the
  /// blob here from a machine that has it.
  readonly missingBlobs: ReadonlyArray<{
    readonly directoryName: string
    readonly hash: string
  }>
}

export interface SkillsSyncResult {
  readonly status: SkillsSyncStatus
  /// Entries the reconcile changed in the "skills" replica — what the route
  /// publishes as sync.changed.
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

export interface SkillsSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly skills: SkillsManager
  readonly blobs: BlobStore
  readonly serverId: string
  readonly now?: () => number
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const tarExec = (args: ReadonlyArray<string>, input?: Buffer): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    const child = spawn("tar", args)
    const chunks: Array<Buffer> = []
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk))
    child.once("error", reject)
    child.once("close", (code) =>
      code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error(`tar exited with ${code}`))
    )
    if (input !== undefined) child.stdin.write(input)
    child.stdin.end()
  })

/// Packs a skill directory's CONTENTS (not the directory itself, so the
/// destination name is the replica's business, not the archive's).
export const packSkillArchive = (skillPath: string): Promise<Buffer> =>
  tarExec(["-czf", "-", "-C", skillPath, "."])

const EXCLUDED: ReadonlySet<string> = new Set([MANAGED_MARKER])

/// Unpacks an archive into a fresh temp directory and returns its path and
/// tree hash — the caller compares the hash to the claimed blob id (and
/// owns removing the temp directory).
export const unpackSkillArchive = async (
  bytes: Buffer
): Promise<{ readonly path: string; readonly hash: string }> => {
  const path = await mkdtemp(join(tmpdir(), "codevisor-skill-"))
  await tarExec(["-xzf", "-", "-C", path], bytes)
  return { path, hash: await treeHash(path, { exclude: EXCLUDED }) }
}

export const skillTreeHash = (path: string): Promise<string> =>
  treeHash(path, { exclude: EXCLUDED })

interface SkillEntryValue {
  readonly hash?: unknown
  readonly name?: unknown
}

const entryHash = (entry: SyncEntryRecord): string | undefined => {
  if (entry.deleted === true) return undefined
  const value = entry.value as SkillEntryValue | null | undefined
  return typeof value?.hash === "string" ? value.hash : undefined
}

/// One reconcile pass; see the module doc for the model.
export const reconcileSkills = async (deps: SkillsSyncDeps): Promise<SkillsSyncResult> => {
  const now = deps.now ?? Date.now
  const scan = await deps.skills.list()
  const localSkills = new Map(scan.global.map((skill) => [skill.directoryName, skill]))
  const localHashes = new Map<string, string>()
  for (const [directoryName, skill] of localSkills) {
    localHashes.set(directoryName, await skillTreeHash(skill.path))
  }
  const replica = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const appliedByKey = new Map(
    appliedEntries
      .filter((entry) => entry.deleted !== true && typeof entry.value === "string")
      .map((entry) => [entry.key, entry.value as string])
  )

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const renamed: Array<{ from: string; to: string }> = []
  const missingBlobs: Array<{ directoryName: string; hash: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncEntryRecord["timestamp"] => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }

  // Local state drives publications: a skill whose content differs from
  // what this machine last published/applied is a local creation or edit.
  // First contact is the exception: when the replica already names a skill
  // this machine never applied, an identical copy is adopted in place and
  // a different one moves aside — a join never silently overwrites either
  // side (the fleet version applies under the original name below).
  for (const [directoryName, skill] of [...localSkills]) {
    const localHash = localHashes.get(directoryName) as string
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
      path = join(scan.canonicalDir, key)
      await rename(join(scan.canonicalDir, directoryName), path)
      localSkills.delete(directoryName)
      localHashes.delete(directoryName)
      localSkills.set(key, { ...skill, directoryName: key, path })
      localHashes.set(key, localHash)
      await deps.skills.sync({ directoryNames: [key] })
      renamed.push({ from: directoryName, to: key })
    }
    if (!deps.blobs.has(localHash)) {
      deps.blobs.write(localHash, await packSkillArchive(path))
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

  // A skill this machine once had (applied is recorded) that is gone from
  // the canonical store was deleted here: publish the tombstone.
  for (const [directoryName] of appliedByKey) {
    if (localSkills.has(directoryName)) continue
    if (replicaByKey.get(directoryName)?.deleted === true) continue
    replicaWrites.push({ key: directoryName, value: null, deleted: true, timestamp: stamp() })
    appliedWrites.push({ key: directoryName, value: null, deleted: true, timestamp: stamp() })
    published.push(directoryName)
  }

  // Merge local publications first so the replica below reflects them.
  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))

  // Replica drives applications: entries whose hash this machine has not
  // applied are unpacked (when the blob is here) or reported missing.
  for (const entry of merged) {
    const directoryName = entry.key
    const wantedHash = entryHash(entry)
    const localHash = localHashes.get(directoryName)
    if (wantedHash === undefined) {
      // Tombstone: remove the local copy unless a local edit republished
      // above (in which case our newer entry already replaced it).
      if (localSkills.has(directoryName) && appliedByKey.get(directoryName) === localHash) {
        await deps.skills.remove(directoryName)
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
        // A corrupt blob must not poison the canonical store; drop it so a
        // client ferries a fresh copy.
        deps.blobs.remove(wantedHash)
        missingBlobs.push({ directoryName, hash: wantedHash })
        continue
      }
      const destination = join(scan.canonicalDir, directoryName)
      await rm(destination, { recursive: true, force: true })
      await cp(unpacked.path, destination, { recursive: true, verbatimSymlinks: true })
      await deps.skills.sync({ directoryNames: [directoryName] })
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

/// PUT /v1/sync/blobs verification: the archive's unpacked tree hash must
/// equal the claimed id, or the bytes are rejected.
export const verifySkillArchive = async (id: string, bytes: Buffer): Promise<boolean> => {
  try {
    const unpacked = await unpackSkillArchive(bytes)
    const matches = unpacked.hash === id
    await rm(unpacked.path, { recursive: true, force: true })
    return matches
  } catch {
    // Bytes tar cannot unpack are just as rejected as a hash mismatch.
    return false
  }
}
