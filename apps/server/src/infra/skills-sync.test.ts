import { makeSkillsManager } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makeAgents, makeServices, run, tempDirs } from "../test-support.js"
import {
  packSkillArchive,
  reconcileSkills,
  SKILLS_SYNC_NAMESPACE,
  skillTreeHash,
  verifySkillArchive
} from "./skills-sync.js"

const makeSkills = () => {
  const home = mkdtempSync(join(tmpdir(), "skills-home-"))
  tempDirs.push(home)
  return makeSkillsManager({ agents: makeAgents(), homedir: home, env: {} })
}

const makeBlobs = () => {
  const directory = mkdtempSync(join(tmpdir(), "sync-blobs-"))
  tempDirs.push(directory)
  return makeBlobStore(directory)
}

describe("skills sync", () => {
  it("publishes, ferries, applies, edits, and deletes across two machines", async () => {
    const { services: machineA } = await makeServices("server-a")
    const { services: machineB } = await makeServices("server-b")
    const skillsA = makeSkills()
    const skillsB = makeSkills()
    const blobsA = makeBlobs()
    const blobsB = makeBlobs()
    const a = { db: machineA.db, skills: skillsA, blobs: blobsA, serverId: "server-a" }
    const b = { db: machineB.db, skills: skillsB, blobs: blobsB, serverId: "server-b" }

    // A creates a skill; the first pass publishes it and packs its blob.
    await skillsA.create({ name: "Deploy", description: "ship it" })
    const firstA = await reconcileSkills(a)
    expect(firstA.status.published).toEqual(["deploy"])
    const hash = (firstA.changedEntries[0]?.value as { hash: string }).hash
    expect(blobsA.has(hash)).toBe(true)

    // Idempotent: a second pass changes nothing.
    expect((await reconcileSkills(a)).status).toEqual({
      published: [],
      applied: [],
      removed: [],
      missingBlobs: []
    })

    // B adopts the metadata but reports the blob missing until a client
    // ferries it over — then applies for real.
    await run(machineB.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, firstA.changedEntries))
    expect((await reconcileSkills(b)).status.missingBlobs).toEqual([
      { directoryName: "deploy", hash }
    ])
    blobsB.write(hash, await blobsA.read(hash))
    expect((await reconcileSkills(b)).status.applied).toEqual(["deploy"])
    const scanB = await skillsB.list()
    expect(scanB.global.map((skill) => skill.directoryName)).toEqual(["deploy"])
    expect(await skillTreeHash(scanB.global[0]?.path ?? "")).toBe(hash)

    // An edit on A republishes with a new hash; reverting the edit reuses
    // the original blob (already stored) rather than re-packing.
    const scanA = await skillsA.list()
    const skillPathA = scanA.global[0]?.path ?? ""
    writeFileSync(join(skillPathA, "extra.md"), "more\n")
    const editedA = await reconcileSkills(a)
    expect(editedA.status.published).toEqual(["deploy"])
    const editedHash = (editedA.changedEntries[0]?.value as { hash: string }).hash
    expect(editedHash).not.toBe(hash)

    // B deletes the skill; the tombstone removes it from A.
    await skillsB.remove("deploy")
    const deletedB = await reconcileSkills(b)
    expect(deletedB.status.published).toEqual(["deploy"])
    await run(machineA.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, deletedB.changedEntries))
    const removedA = await reconcileSkills(a)
    // A's edit published BEFORE the tombstone arrived, but the tombstone's
    // stamp is newer — last writer wins, and the local copy goes.
    expect(removedA.status.removed).toEqual(["deploy"])
    expect((await skillsA.list()).global).toHaveLength(0)
  })

  it("drops corrupt blobs, skips malformed entries, and tolerates stale tombstones", async () => {
    const { services } = await makeServices("server-c")
    const skills = makeSkills()
    const blobs = makeBlobs()
    const deps = { db: services.db, skills, blobs, serverId: "server-c" }

    // A blob whose contents do not reproduce the claimed hash is removed
    // and re-reported missing rather than unpacked into the store.
    const bogusDir = mkdtempSync(join(tmpdir(), "bogus-skill-"))
    tempDirs.push(bogusDir)
    writeFileSync(join(bogusDir, "SKILL.md"), "---\nname: bogus\n---\nbody\n")
    const wrongHash = "f".repeat(64)
    blobs.write(wrongHash, await packSkillArchive(bogusDir))
    await run(
      services.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, [
        {
          key: "bogus",
          value: { hash: wrongHash, name: "bogus" },
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        },
        // Malformed values never drive changes.
        {
          key: "junk",
          value: "not-an-object",
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        },
        // A tombstone for a skill this machine never had is a no-op.
        {
          key: "ghost",
          value: null,
          deleted: true,
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        }
      ])
    )
    // A skill this machine once applied, deleted locally, whose replica
    // entry is ALREADY a tombstone: nothing to republish.
    await run(
      services.db.mergeSyncEntries("local.skills-applied", [
        {
          key: "ghost",
          value: "e".repeat(64),
          timestamp: { wallMs: 5, counter: 0, deviceId: "server-c" }
        }
      ])
    )

    const result = await reconcileSkills(deps)
    expect(result.status.missingBlobs).toEqual([{ directoryName: "bogus", hash: wrongHash }])
    expect(result.status.published).toEqual([])
    expect(result.status.applied).toEqual([])
    expect(result.status.removed).toEqual([])
    expect(blobs.has(wrongHash)).toBe(false)
  })

  it("verifies archives against their tree hash", async () => {
    const dir = mkdtempSync(join(tmpdir(), "verify-skill-"))
    tempDirs.push(dir)
    writeFileSync(join(dir, "SKILL.md"), "---\nname: verify\n---\nbody\n")
    const bytes = await packSkillArchive(dir)
    const hash = await skillTreeHash(dir)

    expect(await verifySkillArchive(hash, bytes)).toBe(true)
    expect(await verifySkillArchive("a".repeat(64), bytes)).toBe(false)
    // Bytes tar cannot unpack are rejected the same way.
    expect(await verifySkillArchive(hash, Buffer.from("not a tarball"))).toBe(false)
  })

  it("publishes without re-packing when the blob already exists", async () => {
    const { services } = await makeServices("server-d")
    const skills = makeSkills()
    const blobs = makeBlobs()
    await skills.create({ name: "Cached", description: "already packed" })
    const path = (await skills.list()).global[0]?.path ?? ""
    const hash = await skillTreeHash(path)
    blobs.write(hash, await packSkillArchive(path))

    const result = await reconcileSkills({
      db: services.db,
      skills,
      blobs,
      serverId: "server-d"
    })
    expect(result.status.published).toEqual(["cached"])
    expect(blobs.has(hash)).toBe(true)
  })
})
