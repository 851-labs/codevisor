import { describe, expect, it } from "vitest"

import {
  initialNewChatDraftState,
  moveNewChatDraftToProject,
  newChatDraftAfterSessionCreation,
  updateNewChatHarnessConfig
} from "./useNewChatDraftState"

describe("new-chat draft state", () => {
  it("keeps config selections isolated by harness", () => {
    const codex = updateNewChatHarnessConfig(
      initialNewChatDraftState(),
      "codex",
      "model",
      "gpt-5.6"
    )
    const claude = updateNewChatHarnessConfig(codex, "claude", "model", "opus")

    expect(claude.configByHarness).toEqual({
      codex: { model: "gpt-5.6" },
      claude: { model: "opus" }
    })
  })

  it("turns successful draft choices into defaults while clearing transient state", () => {
    const active = {
      ...initialNewChatDraftState(),
      selectedProjectId: "project-1",
      selectedHarnessId: "codex",
      pendingModeId: "plan",
      isGoalComposerArmed: true,
      error: "retrying",
      setupWorktreeId: "worktree-1",
      setupPhases: [{
        id: "phase-1",
        activeTitle: "Setting up worktree",
        completedTitle: "Set up worktree",
        failedTitle: "Could not set up worktree",
        startedAt: "2026-07-09T00:00:00.000Z",
        outcome: "running" as const,
        logs: []
      }]
    }

    expect(
      newChatDraftAfterSessionCreation(active, {
        selectedHarnessId: "codex",
        runInWorktree: true,
        config: { model: "gpt-5.6", thought_level: "high" }
      })
    ).toEqual({
      selectedHarnessId: "codex",
      runInWorktree: true,
      configByHarness: { codex: { model: "gpt-5.6", thought_level: "high" } },
      isGoalComposerArmed: false,
      setupPhases: []
    })
  })

  it("does not promote unsent choices from a different harness", () => {
    const active = updateNewChatHarnessConfig(
      initialNewChatDraftState(),
      "claude",
      "model",
      "unsent-opus"
    )
    const next = newChatDraftAfterSessionCreation(
      active,
      {
        selectedHarnessId: "codex",
        runInWorktree: false,
        config: { model: "gpt-5.6" }
      },
      {
        selectedHarnessId: "claude",
        runInWorktree: true,
        configByHarness: { claude: { model: "previous-sonnet" } }
      }
    )

    expect(next.configByHarness).toEqual({
      claude: { model: "previous-sonnet" },
      codex: { model: "gpt-5.6" }
    })
  })

  it("preserves a retained failure until the draft moves to another project", () => {
    const failed = {
      ...initialNewChatDraftState(),
      selectedProjectId: "project-1",
      runInWorktree: true,
      pendingModeId: "plan",
      error: "Could not set up worktree",
      setupWorktreeId: "worktree-1"
    }

    expect(moveNewChatDraftToProject(failed, "project-1", false)).toMatchObject({
      selectedProjectId: "project-1",
      runInWorktree: false,
      pendingModeId: "plan",
      error: "Could not set up worktree",
      setupWorktreeId: "worktree-1"
    })
    expect(moveNewChatDraftToProject(failed, "project-2", true)).toMatchObject({
      selectedProjectId: "project-2",
      runInWorktree: true,
      setupPhases: []
    })
    expect(moveNewChatDraftToProject(failed, "project-2", true).error).toBeUndefined()
  })
})
