import { rm } from "node:fs/promises"
import { join } from "node:path"

import type { Skill } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SkillStore } from "@codevisor/skills"
import { freeSyncKey, type BlobStore, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { stringField } from "../unknown-values.js"
import {
  packSkillArchive,
  skillTreeHash,
  unpackSkillArchive,
  verifySkillArchive
} from "./skill-archive.js"
import { blobUnverified, markBlobVerified } from "./skill-blobs.js"
import { keyedEntries, mergePending, openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export {
  archiveEntryNames,
  packSkillArchive,
  skillTreeHash,
  unpackSkillArchive,
  verifySkillArchive
} from "./skill-archive.js"

export const SKILLS_SYNC_NAMESPACE = "codevisor-skills"
const APPLIED_NAMESPACE = "local.codevisor-skills-applied"

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

export const reconcileSkills = async (deps: SkillsSyncDeps): Promise<SkillsSyncResult> => {
  const localSkills = new Map(
    (await deps.store.list()).skills.map((skill) => [skill.directoryName, skill])
  )
  const hashedSkills: Array<HashedSkill> = []
  for (const [directoryName, skill] of localSkills) {
    hashedSkills.push({ directoryName, skill, localHash: await skillTreeHash(skill.path) })
  }
  const replica = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))
  const replicaByKey = keyedEntries(replica)
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const ledger = openSyncLedger({ owner: deps, replica, applied: appliedEntries })
  const sync = openSkillSync(localSkills, hashedSkills, replicaByKey, ledger)

  for (const hashed of hashedSkills) {
    const { directoryName, skill, localHash } = hashed
    if (blobUnverified(deps, localHash)) {
      let stored = deps.blobs.has(localHash)
      if (stored) stored = await verifySkillArchive(localHash, await deps.blobs.read(localHash))
      if (!stored) deps.blobs.write(localHash, await packSkillArchive(skill.path))
      markBlobVerified(localHash)
    }

    const step = localSkillStep(sync, directoryName, localHash)
    if (step === "skip") continue
    if (step === "adopt") {
      ledger.markApplied(directoryName, () => localHash)
      continue
    }
    if (step === "publish") {
      publishSkill(sync, directoryName, hashed)
      continue
    }

    const key = freeSkillName(sync, directoryName)
    const path = join(deps.store.dir, key)
    await deps.store.rename(directoryName, key)
    renameLocalSkill(sync, hashed, key, path)
    publishSkill(sync, key, hashed)
  }
  ledger.retractUnlisted(localSkills, replicaByKey, sync.published)

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  const replicaMerge = mergePending(deps, SKILLS_SYNC_NAMESPACE, ledger.replicaWrites)
  if (replicaMerge !== undefined) changedEntries = (await replicaMerge).changed
  const merged = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))

  for (const entry of merged) {
    const directoryName = entry.key
    const wantedHash = entryHash(entry)
    const localHash = sync.localHashes.get(directoryName)
    if (wantedHash === undefined) {
      if (!isUnchangedLocal(ledger, localSkills, directoryName, localHash)) continue

      await deps.store.remove(directoryName)
      ledger.markRemoved(directoryName)
      sync.removed.push(directoryName)
      continue
    }

    if (holdsHash(ledger, directoryName, localHash, wantedHash)) continue
    if (!deps.blobs.has(wantedHash)) {
      recordMissingBlob(sync, directoryName, wantedHash)
      continue
    }

    const unpacked = await unpackSkillArchive(await deps.blobs.read(wantedHash))
    try {
      if (unpacked.hash !== wantedHash) {
        deps.blobs.remove(wantedHash)
        recordMissingBlob(sync, directoryName, wantedHash)
        continue
      }
      await deps.store.replace(directoryName, unpacked.path)
      ledger.markApplied(directoryName, () => wantedHash)
      sync.applied.push(directoryName)
    } finally {
      await rm(unpacked.path, { recursive: true, force: true })
    }
  }

  const appliedMerge = mergePending(deps, APPLIED_NAMESPACE, ledger.appliedWrites)
  if (appliedMerge !== undefined) await appliedMerge
  return { status: skillsStatus(sync), changedEntries }
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

interface SkillSync {
  readonly localSkills: Map<string, Skill>
  readonly localHashes: Map<string, string>
  readonly replicaByKey: ReadonlyMap<string, SyncEntryRecord>
  readonly ledger: SyncLedger
  readonly published: Array<string>
  readonly renamed: Array<SkillRename>
  readonly applied: Array<string>
  readonly removed: Array<string>
  readonly missingBlobs: Array<MissingSkillBlob>
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const entryHash = (entry: SyncEntryRecord): string | undefined =>
  entry.deleted === true ? undefined : stringField(entry.value, "hash")

type LocalSkillStep = "skip" | "publish" | "adopt" | "rename"

const openSkillSync = (
  localSkills: Map<string, Skill>,
  hashedSkills: ReadonlyArray<HashedSkill>,
  replicaByKey: ReadonlyMap<string, SyncEntryRecord>,
  ledger: SyncLedger
): SkillSync => ({
  localSkills,
  localHashes: new Map(hashedSkills.map((hashed) => [hashed.directoryName, hashed.localHash])),
  replicaByKey,
  ledger,
  published: [],
  renamed: [],
  applied: [],
  removed: [],
  missingBlobs: []
})

const localSkillStep = (
  sync: SkillSync,
  directoryName: string,
  localHash: string
): LocalSkillStep => {
  if (sync.ledger.applied.get(directoryName) === localHash) return "skip"

  const existing = sync.replicaByKey.get(directoryName)
  const replicaHash = existing === undefined ? undefined : entryHash(existing)
  if (!replicaClaimsName(sync.ledger, directoryName, replicaHash)) return "publish"
  if (replicaHash === localHash) return "adopt"
  return "rename"
}

const freeSkillName = (sync: SkillSync, directoryName: string): string =>
  freeSyncKey(directoryName, (candidate) => nameTaken(sync, candidate))

const renameLocalSkill = (
  sync: SkillSync,
  { directoryName, skill, localHash }: HashedSkill,
  key: string,
  path: string
): void => {
  sync.localSkills.delete(directoryName)
  sync.localHashes.delete(directoryName)
  sync.localSkills.set(key, { ...skill, directoryName: key, path })
  sync.localHashes.set(key, localHash)
  sync.renamed.push({ from: directoryName, to: key })
}

const publishSkill = (sync: SkillSync, key: string, { skill, localHash }: HashedSkill): void => {
  sync.ledger.publish(key, { hash: localHash, name: skill.name }, () => localHash)
  sync.published.push(key)
}

const recordMissingBlob = (sync: SkillSync, directoryName: string, hash: string): void => {
  sync.missingBlobs.push({ directoryName, hash })
}

const skillsStatus = (sync: SkillSync): SkillsSyncStatus => ({
  published: sync.published,
  applied: sync.applied,
  removed: sync.removed,
  renamed: sync.renamed,
  missingBlobs: sync.missingBlobs
})

const replicaClaimsName = (
  ledger: SyncLedger,
  directoryName: string,
  replicaHash: string | undefined
): replicaHash is string => !ledger.applied.has(directoryName) && replicaHash !== undefined

const nameTaken = (sync: SkillSync, candidate: string): boolean =>
  sync.localSkills.has(candidate) || sync.replicaByKey.has(candidate)

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
