import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { gzipSync } from "node:zlib"

import { makeSkillStore } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { Schema } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeServices, run, tempDirs } from "../test-support.js"
import {
  packSkillArchive,
  reconcileSkills,
  SKILLS_SYNC_NAMESPACE,
  skillTreeHash,
  verifySkillArchive,
  archiveEntryNames
} from "./skills-sync.js"

const makeSkills = () => {
  const home = mkdtempSync(join(tmpdir(), "skills-home-"))
  tempDirs.push(home)
  return makeSkillStore({ dir: join(home, "skills") })
}

const makeBlobs = () => {
  const directory = mkdtempSync(join(tmpdir(), "sync-blobs-"))
  tempDirs.push(directory)
  return makeBlobStore(directory)
}

const hashOf = (value: unknown): string =>
  Schema.decodeUnknownSync(Schema.Struct({ hash: Schema.String }))(value).hash

const elsewhereAt = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

const skillsSyncClock = (wallMs: number) => {
  const now = vi.spyOn(Date, "now").mockReturnValue(wallMs)
  onTestFinished(() => now.mockRestore())
  return now
}

describe("skills sync", () => {
  it("publishes, ferries, applies, edits, and deletes across two machines", async () => {
    const now = skillsSyncClock(1_700_000_000_000)
    const { services: machineA } = await makeServices("server-a")
    const { services: machineB } = await makeServices("server-b")
    const skillsA = makeSkills()
    const skillsB = makeSkills()
    const blobsA = makeBlobs()
    const blobsB = makeBlobs()
    const a = { db: machineA.db, store: skillsA, blobs: blobsA, serverId: "server-a" }
    const b = { db: machineB.db, store: skillsB, blobs: blobsB, serverId: "server-b" }

    await skillsA.create({ name: "Deploy", description: "ship it" })
    const firstA = await reconcileSkills(a)
    expect(firstA.status.published).toEqual(["deploy"])
    const hash = hashOf(firstA.changedEntries[0]?.value)
    expect(blobsA.has(hash)).toBe(true)

    expect((await reconcileSkills(a)).status).toEqual({
      published: [],
      applied: [],
      removed: [],
      renamed: [],
      missingBlobs: []
    })

    await run(machineB.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, firstA.changedEntries))
    expect((await reconcileSkills(b)).status.missingBlobs).toEqual([
      { directoryName: "deploy", hash }
    ])
    blobsB.write(hash, await blobsA.read(hash))
    expect((await reconcileSkills(b)).status.applied).toEqual(["deploy"])
    const scanB = await skillsB.list()
    expect(scanB.skills.map((skill) => skill.directoryName)).toEqual(["deploy"])
    expect(await skillTreeHash(scanB.skills[0]?.path ?? "")).toBe(hash)

    const scanA = await skillsA.list()
    const skillPathA = scanA.skills[0]?.path ?? ""
    writeFileSync(join(skillPathA, "extra.md"), "more\n")
    const editedA = await reconcileSkills(a)
    expect(editedA.status.published).toEqual(["deploy"])
    const editedHash = hashOf(editedA.changedEntries[0]?.value)
    expect(editedHash).not.toBe(hash)

    now.mockReturnValue(1_700_000_001_000)
    await skillsB.remove("deploy")
    const deletedB = await reconcileSkills(b)
    expect(deletedB.status.published).toEqual(["deploy"])
    await run(machineA.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, deletedB.changedEntries))
    const removedA = await reconcileSkills(a)
    expect(removedA.status.removed).toEqual(["deploy"])
    expect((await skillsA.list()).skills).toHaveLength(0)
  })

  it("drops corrupt blobs, skips malformed entries, and tolerates stale tombstones", async () => {
    const { services } = await makeServices("server-c")
    const skills = makeSkills()
    const blobs = makeBlobs()
    const deps = { db: services.db, store: skills, blobs, serverId: "server-c" }

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
        {
          key: "junk",
          value: "not-an-object",
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        },
        {
          key: "ghost",
          value: null,
          deleted: true,
          timestamp: { wallMs: 10, counter: 0, deviceId: "elsewhere" }
        }
      ])
    )
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

  it("doesn't republish a deletion the fleet already recorded", async () => {
    skillsSyncClock(1_700_000_000_000)
    const { services } = await makeServices("server-tomb")
    const store = makeSkills()
    const deps = { db: services.db, store, blobs: makeBlobs(), serverId: "server-tomb" }
    await store.create({ name: "Deploy", description: "ship it" })
    await reconcileSkills(deps)
    await run(
      services.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, [
        { key: "deploy", value: null, deleted: true, timestamp: elsewhereAt(1_700_000_060_000) }
      ])
    )
    await store.remove("deploy")
    const result = await reconcileSkills(deps)
    expect(result.status.published).toEqual([])
    expect(result.changedEntries).toEqual([])
  })

  it("verifies archives against their tree hash", async () => {
    const dir = mkdtempSync(join(tmpdir(), "verify-skill-"))
    tempDirs.push(dir)
    writeFileSync(join(dir, "SKILL.md"), "---\nname: verify\n---\nbody\n")
    const bytes = await packSkillArchive(dir)
    const hash = await skillTreeHash(dir)

    expect(await verifySkillArchive(hash, bytes)).toBe(true)
    expect(await verifySkillArchive("a".repeat(64), bytes)).toBe(false)
    expect(await verifySkillArchive(hash, Buffer.from("not a tarball"))).toBe(false)
  })

  it("rejects a large upload tar stops reading without crashing the server", async () => {
    const bin = mkdtempSync(join(tmpdir(), "codevisor-fake-tar-"))
    tempDirs.push(bin)
    writeFileSync(join(bin, "tar"), "#!/bin/sh\nexit 2\n", { mode: 0o755 })
    vi.stubEnv("PATH", `${bin}:${process.env.PATH ?? ""}`)
    try {
      const archive = gzipSync(Buffer.alloc(4 * 1024 * 1024, "A"), { level: 0 })
      expect(await verifySkillArchive("a".repeat(64), archive)).toBe(false)
    } finally {
      vi.unstubAllEnvs()
    }
  })

  it("syncs a skill folder Finder visited, leaving its OS junk behind", async () => {
    const { services: machineA } = await makeServices("server-a")
    const { services: machineB } = await makeServices("server-b")
    const skillsA = makeSkills()
    const skillsB = makeSkills()
    const blobsA = makeBlobs()
    const blobsB = makeBlobs()
    const a = { db: machineA.db, store: skillsA, blobs: blobsA, serverId: "server-a" }
    const b = { db: machineB.db, store: skillsB, blobs: blobsB, serverId: "server-b" }
    await skillsA.create({ name: "Finder", description: "visited" })
    const pathA = (await skillsA.list()).skills[0]?.path ?? ""
    mkdirSync(join(pathA, "refs"))
    writeFileSync(join(pathA, "refs", "notes.md"), "notes\n")
    for (const junk of [".DS_Store", "._SKILL.md", join("refs", ".DS_Store")]) {
      writeFileSync(join(pathA, junk), "finder")
    }

    const published = await reconcileSkills(a)
    const hash = hashOf(published.changedEntries[0]?.value)
    const archive = await blobsA.read(hash)
    expect(await verifySkillArchive(hash, archive)).toBe(true)

    await run(machineB.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, published.changedEntries))
    await reconcileSkills(b)
    blobsB.write(hash, archive)
    expect((await reconcileSkills(b)).status.applied).toEqual(["finder"])
    const pathB = join(skillsB.dir, "finder")
    expect(
      readdirSync(pathB, { recursive: true, encoding: "utf8" }).toSorted((left, right) =>
        left.localeCompare(right)
      )
    ).toEqual(["refs", join("refs", "notes.md"), "SKILL.md"])

    writeFileSync(join(pathB, ".DS_Store"), "finder")
    expect((await reconcileSkills(b)).status.published).toEqual([])
  })

  it("rejects archives carrying macOS metadata junk even when the tree hash matches", async () => {
    const folder = mkdtempSync(join(tmpdir(), "skill-junk-"))
    tempDirs.push(folder)
    writeFileSync(join(folder, "SKILL.md"), "---\nname: Junked\n---\n")
    writeFileSync(join(folder, ".DS_Store"), "finder")
    const junkArchive = execFileSync("tar", ["-czf", "-", "-C", folder, "."], {
      env: { ...process.env, COPYFILE_DISABLE: "1" }
    })
    expect(archiveEntryNames(junkArchive)).toContain("./.DS_Store")
    expect(await verifySkillArchive(await skillTreeHash(folder), junkArchive)).toBe(false)

    const emptySize = Buffer.alloc(512)
    emptySize.write("/", 0, "utf8")
    expect(archiveEntryNames(gzipSync(Buffer.concat([emptySize, Buffer.alloc(1024)])))).toEqual([
      "/"
    ])
    expect(
      await verifySkillArchive(
        "a".repeat(64),
        gzipSync(Buffer.concat([emptySize, Buffer.alloc(1024)]))
      )
    ).toBe(false)
  })

  it("repacks a tainted cached blob and settles afterward", async () => {
    const { services } = await makeServices("server-d")
    const skills = makeSkills()
    const blobs = makeBlobs()
    await skills.create({ name: "Cached", description: "already packed" })
    const path = (await skills.list()).skills[0]?.path ?? ""
    const hash = await skillTreeHash(path)
    blobs.write(hash, Buffer.from("not an archive"))

    await skills.create({ name: "Prepacked", description: "good archive" })
    const prepackedPath =
      (await skills.list()).skills.find((skill) => skill.name === "Prepacked")?.path ?? ""
    const prepackedHash = await skillTreeHash(prepackedPath)
    blobs.write(prepackedHash, await packSkillArchive(prepackedPath))

    const result = await reconcileSkills({
      db: services.db,
      store: skills,
      blobs,
      serverId: "server-d"
    })
    expect(result.status.published.toSorted()).toEqual(["cached", "prepacked"])
    expect(await verifySkillArchive(hash, await blobs.read(hash))).toBe(true)
    expect(await verifySkillArchive(prepackedHash, await blobs.read(prepackedHash))).toBe(true)

    const again = await reconcileSkills({
      db: services.db,
      store: skills,
      blobs,
      serverId: "server-d"
    })
    expect(again.status.published).toEqual([])

    blobs.remove(hash)
    expect(blobs.has(hash)).toBe(false)
    await reconcileSkills({ db: services.db, store: skills, blobs, serverId: "server-d" })
    expect(await verifySkillArchive(hash, await blobs.read(hash))).toBe(true)
  })

  it("adopts identical and renames conflicting first-contact skills", async () => {
    const { services } = await makeServices("server-d")
    const skills = makeSkills()
    const blobs = makeBlobs()
    const deps = { db: services.db, store: skills, blobs, serverId: "server-d" }

    await skills.create({ name: "Deploy", description: "local flavor" })
    await skills.create({ name: "Deploy 2", description: "same everywhere" })
    await skills.create({ name: "Ghost", description: "returns" })
    const scan = await skills.list()
    const deploy2Path = scan.skills.find((s) => s.directoryName === "deploy-2")?.path ?? ""
    const sameHash = await skillTreeHash(deploy2Path)
    await run(
      services.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, [
        {
          key: "deploy",
          value: { hash: "a".repeat(64), name: "Deploy" },
          timestamp: elsewhereAt(10)
        },
        {
          key: "deploy-2",
          value: { hash: sameHash, name: "Deploy 2" },
          timestamp: elsewhereAt(11)
        },
        {
          key: "deploy-3",
          value: { hash: "b".repeat(64), name: "Deploy 3" },
          timestamp: elsewhereAt(12)
        },
        { key: "ghost", value: null, deleted: true, timestamp: elsewhereAt(13) }
      ])
    )

    const result = await reconcileSkills(deps)

    expect(result.status.renamed).toEqual([{ from: "deploy", to: "deploy-4" }])
    expect([...result.status.published].toSorted()).toEqual(["deploy-4", "ghost"])
    expect(result.status.applied).toEqual([])
    expect([...result.status.missingBlobs].map((b) => b.directoryName).toSorted()).toEqual([
      "deploy",
      "deploy-3"
    ])
    const names = (await skills.list()).skills.map((s) => s.directoryName).toSorted()
    expect(names).toEqual(["deploy-2", "deploy-4", "ghost"])
    const republished = result.changedEntries.find((e) => e.key === "deploy-4")
    expect(await skillTreeHash(join(scan.dir, "deploy-4"))).toBe(hashOf(republished?.value))
  })
})
