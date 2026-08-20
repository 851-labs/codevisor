import { describe, expect, it } from "vitest"
import {
  grokAskUserQuestion,
  grokGoalNotification,
  grokModeState,
  grokPlanApprovalQuestion
} from "./index.js"

describe("Grok Build compatibility", () => {
  it("advertises the modes Grok implements but does not report", () => {
    expect(grokModeState.currentModeId).toBe("default")
    expect(grokModeState.availableModes.map((mode) => [mode.id, mode.canonicalId])).toEqual([
      ["default", "fullAccess"],
      ["plan", "plan"],
      ["ask", "ask"]
    ])
  })

  it("maps Grok plan approval responses and plan markdown", () => {
    const mapped = grokPlanApprovalQuestion({
      sessionId: "s-1",
      toolCallId: "tool-1",
      planContent: "# Plan\n\nShip it."
    })
    expect(mapped?.planDocument).toBe("# Plan\n\nShip it.")
    expect(mapped?.questions[0]?.options.map((option) => option.label)).toEqual([
      "Implement plan",
      "Keep planning",
      "Abandon plan"
    ])
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: { grok_exit_plan_mode: { answers: ["Implement plan"] } }
      })
    ).toEqual({ outcome: "approved" })
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: {
          grok_exit_plan_mode: { answers: ["Keep planning"], note: "Add rollback steps" }
        }
      })
    ).toEqual({ outcome: "cancelled", feedback: "Add rollback steps" })
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: { grok_exit_plan_mode: { answers: ["Abandon plan"] } }
      })
    ).toEqual({ outcome: "abandoned" })
  })

  it("maps Grok's blocking questionnaire into Codevisor answers", () => {
    const mapped = grokAskUserQuestion({
      sessionId: "s-1",
      toolCallId: "tool-1",
      mode: "plan",
      questions: [
        {
          question: "Which database?",
          options: [
            {
              label: "SQLite",
              description: "Keep it local",
              preview: "schema preview"
            },
            { label: "Postgres", description: "Use a server" }
          ]
        },
        {
          question: "Anything else?",
          options: [],
          multiSelect: false
        }
      ]
    })
    expect(mapped?.questions).toEqual([
      {
        id: "Which database?",
        question: "Which database?",
        options: [
          { label: "SQLite", description: "Keep it local" },
          { label: "Postgres", description: "Use a server" }
        ],
        allowsOther: true
      },
      {
        id: "Anything else?",
        question: "Anything else?",
        options: [],
        allowsOther: true
      }
    ])
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: {
          "Which database?": { answers: ["SQLite"] },
          "Anything else?": { answers: [], note: "Add backups" }
        }
      })
    ).toEqual({
      outcome: "accepted",
      answers: {
        "Which database?": ["SQLite"],
        "Anything else?": ["Other"]
      },
      annotations: {
        "Which database?": { preview: "schema preview" },
        "Anything else?": { notes: "Add backups" }
      }
    })
  })

  it("maps Grok goal progress and preserves the goal creation time", () => {
    const active = grokGoalNotification(
      {
        sessionId: "s-1",
        update: {
          sessionUpdate: "goal_updated",
          objective: "Ship goal mode",
          status: "active",
          verifying_completion: true,
          token_budget: 20_000,
          tokens_used: 1_250,
          elapsed_ms: 2_500
        }
      },
      undefined,
      "2026-07-16T12:00:00.000Z"
    )
    expect(active?.goal).toEqual({
      objective: "Ship goal mode",
      status: "active",
      activity: "verifying",
      tokenBudget: 20_000,
      tokensUsed: 1_250,
      timeUsedSeconds: 2.5,
      createdAt: "2026-07-16T12:00:00.000Z",
      updatedAt: "2026-07-16T12:00:00.000Z"
    })
    const paused = grokGoalNotification(
      {
        method: "x.ai/session_notification",
        params: {
          sessionId: "s-1",
          update: {
            sessionUpdate: "goal_updated",
            objective: "Ship goal mode",
            status: "back_off_paused",
            tokens_used: 2_000,
            elapsed_ms: 4_000
          }
        }
      },
      () => active?.goal,
      "2026-07-16T12:01:00.000Z"
    )
    expect(paused?.goal?.status).toBe("paused")
    expect(paused?.goal?.createdAt).toBe("2026-07-16T12:00:00.000Z")
    expect(paused?.event.payload).toEqual({ goal: paused?.goal })
  })

  it("maps Grok goal clearing onto the shared cleared event", () => {
    const cleared = grokGoalNotification({
      sessionId: "s-1",
      update: { sessionUpdate: "goal_updated", status: "cleared" }
    })
    expect(cleared).toEqual({
      sessionId: "s-1",
      goal: undefined,
      event: {
        kind: "session.updated",
        subjectId: "s-1",
        payload: { goalCleared: true }
      }
    })
  })
})
