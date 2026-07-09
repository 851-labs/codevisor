import type { EventEnvelope } from "@herdman/api"
import { describe, expect, it } from "vitest"

import {
  applyWorktreeSetupEvent,
  withDeferredAgentPhase,
  worktreePhase,
  worktreeSetupUpdateFrom
} from "./session-setup"

function event(id: number, state: string, payload: Record<string, unknown> = {}): EventEnvelope {
  return {
    id,
    serverId: "local",
    kind: "worktree.setup",
    subjectId: "wt-1",
    payload: {
      state,
      worktreeId: "wt-1",
      projectId: "project-1",
      name: "fix-auth-1234",
      branch: "herdman/fix-auth-1234",
      ...payload
    },
    createdAt: `2026-07-08T10:00:0${id}.000Z`
  }
}

describe("session setup events", () => {
  it("decodes only matching worktree setup events", () => {
    expect(worktreeSetupUpdateFrom(event(1, "started"), "WT-1")?.state).toBe("started")
    expect(
      worktreeSetupUpdateFrom({ ...event(2, "started"), subjectId: "other" }, "wt-1")
    ).toBeUndefined()
    expect(
      worktreeSetupUpdateFrom({ ...event(3, "started"), kind: "session.output" }, "wt-1")
    ).toBeUndefined()
  })

  it("accumulates logs and terminal outcomes", () => {
    let phases = applyWorktreeSetupEvent([], event(1, "started"), "wt-1")
    phases = applyWorktreeSetupEvent(
      phases,
      event(2, "log", { stream: "stderr", line: "Preparing worktree..." }),
      "wt-1"
    )
    phases = applyWorktreeSetupEvent(phases, event(3, "completed", { durationMs: 2000 }), "wt-1")

    expect(phases).toHaveLength(1)
    expect(phases[0]).toMatchObject({
      id: "worktree",
      outcome: "succeeded",
      endedAt: "2026-07-08T10:00:03.000Z",
      logs: [{ id: 0, stream: "stderr", text: "Preparing worktree..." }]
    })
  })

  it("surfaces setup failures", () => {
    const phases = applyWorktreeSetupEvent(
      [],
      event(1, "failed", { message: "branch already exists" }),
      "wt-1"
    )

    expect(phases[0]).toMatchObject({
      outcome: "failed",
      failureMessage: "branch already exists"
    })
  })

  it("adds a deferred agent phase after worktree setup finishes", () => {
    const runningWorktree = worktreePhase("2026-07-08T10:00:00.000Z")
    expect(
      withDeferredAgentPhase([runningWorktree], {
        hasDeferredAgent: true,
        agentName: "Claude Code",
        startedAt: "2026-07-08T10:00:01.000Z"
      })
    ).toEqual([runningWorktree])

    const completedWorktree = {
      ...runningWorktree,
      outcome: "succeeded" as const,
      endedAt: "2026-07-08T10:00:02.000Z"
    }
    expect(
      withDeferredAgentPhase([completedWorktree], {
        hasDeferredAgent: true,
        agentName: "Claude Code",
        startedAt: "2026-07-08T10:00:02.000Z"
      })
    ).toMatchObject([
      { id: "worktree", outcome: "succeeded" },
      {
        id: "agent",
        activeTitle: "Starting Claude Code",
        completedTitle: "Started Claude Code",
        outcome: "running"
      }
    ])

    expect(
      withDeferredAgentPhase([completedWorktree], {
        hasDeferredAgent: false,
        agentName: "Claude Code",
        startedAt: "2026-07-08T10:00:02.000Z"
      })
    ).toEqual([completedWorktree])
  })
})
