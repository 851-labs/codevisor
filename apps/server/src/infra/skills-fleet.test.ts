import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { publishSkillReadiness, skillReadiness, SKILL_READINESS_NAMESPACE } from "./skills-fleet.js"
import { SKILLS_SYNC_NAMESPACE } from "./skills-sync.js"

const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

const skill = (
  directoryName: string,
  installs: ReadonlyArray<string>,
  invalid?: boolean
): {
  readonly directoryName: string
  readonly invalid?: boolean | undefined
  readonly installs: ReadonlyArray<{ readonly state: string }>
} => ({
  directoryName,
  ...(invalid === undefined ? {} : { invalid }),
  installs: installs.map((state) => ({ state }))
})

const fleet = (...names: ReadonlyArray<string>) => new Set(names)

describe("skill readiness mapping", () => {
  it("ranks the states a skill can be in on one machine", () => {
    expect(skillReadiness(skill("dataviz", ["linked", "canonical"]), fleet("dataviz"))).toEqual({
      directoryName: "dataviz",
      state: "ready"
    })
    expect(skillReadiness(skill("dataviz", ["linked", "notInstalled"]), fleet("dataviz"))).toEqual({
      directoryName: "dataviz",
      state: "outOfSync",
      reason: "This skill isn’t available in every harness on this machine yet."
    })
    // Conflict outranks a missing install: the drifted copy is the thing
    // to look at, and syncing would not resolve it.
    expect(
      skillReadiness(skill("dataviz", ["conflict", "notInstalled"]), fleet("dataviz")).state
    ).toBe("conflict")
    // A broken SKILL.md outranks everything — nothing else can be trusted.
    expect(skillReadiness(skill("dataviz", ["conflict"], true), fleet("dataviz")).state).toBe(
      "invalid"
    )
  })

  it("calls a never-published skill machine-only rather than out of sync", () => {
    // Without this, every local draft would raise a warning on the page
    // for failing to be somewhere it was never asked to be.
    expect(skillReadiness(skill("draft", ["notInstalled"]), fleet())).toEqual({
      directoryName: "draft",
      state: "machineOnly"
    })
  })
})

describe("publishSkillReadiness", () => {
  it("publishes one single-writer entry and reports skills whose bytes are missing", async () => {
    const { services } = await makeServices("skill-host")
    const serverId = "skill-host"
    await run(
      services.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, [
        { key: "dataviz", value: { hash: "a", name: "dataviz" }, timestamp: at(1) },
        { key: "vnc-change", value: { hash: "b", name: "vnc-change" }, timestamp: at(2) },
        // A tombstone is not part of the fleet's desired set.
        { key: "retired", value: null, deleted: true, timestamp: at(3) }
      ])
    )
    const skills = {
      list: async () => ({
        canonicalDir: "/tmp/skills",
        global: [skill("dataviz", ["linked"])],
        harnesses: []
      })
    }

    const first = await publishSkillReadiness({
      db: services.db,
      skills: skills as never,
      serverId,
      missingBlobs: ["vnc-change"]
    })
    expect(first.changedEntries).toHaveLength(1)

    const entries = await run(services.db.getSyncEntries(SKILL_READINESS_NAMESPACE))
    expect(entries.map((entry) => entry.key)).toEqual([serverId])
    expect(entries[0]?.value).toEqual({
      skills: [
        { directoryName: "dataviz", state: "ready" },
        {
          directoryName: "vnc-change",
          state: "awaitingContent",
          reason: "Waiting for another machine to send this skill’s content."
        }
      ]
    })

    // Change-detected: a settled machine republishes nothing.
    const second = await publishSkillReadiness({
      db: services.db,
      skills: skills as never,
      serverId,
      missingBlobs: ["vnc-change"]
    })
    expect(second.changedEntries).toHaveLength(0)
  })
})

describe("publishSkillReadiness without a pass", () => {
  it("reports a fleet skill missing here as awaiting content with no reason", async () => {
    const { services } = await makeServices("skill-static")
    await run(
      services.db.mergeSyncEntries(SKILLS_SYNC_NAMESPACE, [
        { key: "dataviz", value: { hash: "a", name: "dataviz" }, timestamp: at(1) }
      ])
    )
    const skills = {
      list: async () => ({ canonicalDir: "/tmp/skills", global: [], harnesses: [] })
    }

    // No missingBlobs: the on-demand publish has no pass to explain why
    // the bytes haven't arrived, so the row carries no reason.
    const result = await publishSkillReadiness({
      db: services.db,
      skills: skills as never,
      serverId: "skill-static",
      now: () => 1_234
    })

    expect(result.changedEntries).toHaveLength(1)
    expect(result.changedEntries[0]?.value).toEqual({
      skills: [{ directoryName: "dataviz", state: "awaitingContent" }]
    })
    expect(result.changedEntries[0]?.timestamp.wallMs).toBe(1_234)
  })
})
