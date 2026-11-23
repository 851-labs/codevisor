import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import {
  installServerAnalytics,
  type ServerAnalyticsEvent
} from "../infra/analytics/server-analytics.js"
import {
  captureAgentLayoutChanged,
  captureSubAgentCreated,
  type BotLookup
} from "./feature-analytics.js"

const captured: ServerAnalyticsEvent[] = []

const install = () =>
  installServerAnalytics({
    capture: async (event) => {
      captured.push(event)
    }
  })

const botOwning = (owned: { sessionId?: string; workspaceId?: string }): BotLookup => ({
  findBotOwning: (query) =>
    Effect.succeed(
      query.sessionId === owned.sessionId || query.workspaceId === owned.workspaceId
        ? { id: "bot" }
        : undefined
    )
})

const session = {
  projectId: "p",
  harnessId: "codex",
  createdAt: "2026-11-22T00:00:00.000Z"
}

afterEach(() => {
  installServerAnalytics(undefined)
  captured.length = 0
})

describe("feature analytics", () => {
  it("reports sub-agents with who started them, and ignores chats people start", async () => {
    install()
    const db = botOwning({ sessionId: "bot-session" })

    await captureSubAgentCreated(db, "machine-a", session)
    await captureSubAgentCreated(db, "machine-a", {
      ...session,
      createdByAgentId: "bot-session",
      createdByAgentMachineId: "machine-b",
      worktreeName: "feature"
    })

    expect(captured).toEqual([
      {
        name: "sub agent created",
        properties: { harness_id: "codex", by_bot: true, other_machine: true, uses_worktree: true }
      }
    ])
  })

  it("reports agent layout changes and whether they happened in a bot", async () => {
    install()
    const db = botOwning({ workspaceId: "bot-workspace" })

    await captureAgentLayoutChanged(db, { workspaceId: "bot-workspace", action: { kind: "split" } })

    expect(captured).toEqual([
      { name: "agent layout changed", properties: { action: "split", in_bot: true } }
    ])
  })
})
