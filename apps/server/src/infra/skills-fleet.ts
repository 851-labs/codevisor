import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SkillsManager } from "@codevisor/skills"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { publishMachineReadiness } from "./config-sync.js"
import { SKILLS_SYNC_NAMESPACE } from "./skills-sync.js"

/// The skills plane's reported half — the fourth readiness instance, after
/// harnesses, MCPs, and plugins. Until now the Skills page derived each
/// machine's condition by fanning `GET /v1/skills` out across the fleet on
/// every visit, which cost N round trips, went blank for an unreachable
/// machine, and could not see the one failure that actually strands a skill:
/// a replica entry whose bytes no client has ferried here yet.
///
/// Single-writer, keyed by this machine's server id, exactly like the other
/// three, so readiness can never conflict.
export const SKILL_READINESS_NAMESPACE = "skill-readiness"

export type SkillReadinessState =
  | "ready"
  | "outOfSync"
  | "awaitingContent"
  | "conflict"
  | "invalid"
  | "machineOnly"

export interface SkillReadinessRow {
  readonly directoryName: string
  readonly state: SkillReadinessState
  readonly reason?: string | undefined
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export interface SkillReadinessDeps {
  readonly db: CodevisorDatabaseService
  readonly skills: SkillsManager
  readonly serverId: string
  /// Tree hashes the last reconcile could not apply because no machine has
  /// ferried their blob here yet. Keyed by directory name.
  readonly missingBlobs: ReadonlyArray<string>
}

/// One skill's condition on this machine. Skills have no enabled flag, so
/// the question is never "on or off" — it is whether the canonical copy is
/// here, whether every harness that needs a materialized copy has one, and
/// whether anything about it is broken.
export const skillReadiness = (
  skill: {
    readonly directoryName: string
    readonly invalid?: boolean | undefined
    readonly installs: ReadonlyArray<{ readonly state: string }>
  },
  fleetNames: ReadonlySet<string>
): SkillReadinessRow => {
  if (skill.invalid === true) {
    return {
      directoryName: skill.directoryName,
      state: "invalid",
      reason: "SKILL.md is missing or its frontmatter could not be read."
    }
  }
  if (skill.installs.some((install) => install.state === "conflict")) {
    return {
      directoryName: skill.directoryName,
      state: "conflict",
      reason: "A harness has its own copy of this skill that has drifted from the canonical one."
    }
  }
  // A local skill the fleet has never seen is not out of sync — it simply
  // has not been published yet, and says so rather than raising a warning.
  if (!fleetNames.has(skill.directoryName)) {
    return { directoryName: skill.directoryName, state: "machineOnly" }
  }
  if (skill.installs.some((install) => install.state === "notInstalled")) {
    return {
      directoryName: skill.directoryName,
      state: "outOfSync",
      reason: "This skill isn’t available in every harness on this machine yet."
    }
  }
  return { directoryName: skill.directoryName, state: "ready" }
}

/// Publishes this machine's skill readiness under its own machine key —
/// single-writer, change-detected, so a settled machine republishes nothing.
export const publishSkillReadiness = async (
  deps: SkillReadinessDeps
): Promise<{ readonly changedEntries: ReadonlyArray<SyncEntryRecord> }> => {
  const scan = await deps.skills.list()
  const desired = await run(deps.db.getSyncEntries(SKILLS_SYNC_NAMESPACE))
  const fleetNames = new Set(
    desired.filter((entry) => entry.deleted !== true).map((entry) => entry.key)
  )
  const localNames = new Set(scan.global.map((skill) => skill.directoryName))
  const awaiting = new Set(deps.missingBlobs)

  const rows: Array<SkillReadinessRow> = scan.global.map((skill) =>
    skillReadiness(skill, fleetNames)
  )
  // Fleet skills this machine doesn't have yet. Without a ferried blob they
  // cannot arrive on their own, which is exactly the state the old page
  // could not distinguish from a healthy skill.
  for (const name of fleetNames) {
    if (localNames.has(name)) continue
    rows.push({
      directoryName: name,
      state: "awaitingContent",
      ...(awaiting.has(name)
        ? { reason: "Waiting for another machine to send this skill’s content." }
        : {})
    })
  }

  return publishMachineReadiness({
    db: deps.db,
    namespace: SKILL_READINESS_NAMESPACE,
    serverId: deps.serverId,
    value: { skills: rows.toSorted((a, b) => a.directoryName.localeCompare(b.directoryName)) }
  })
}
