import type { SessionSummary } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { retireSessionRuntime } from "./server-workspace-effects.js"
import { makeServices } from "./test-support.js"
import { settleCleanup } from "./workspace-runtime.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

const sessionSummary = (id: string, agentSessionId: string): SessionSummary => ({
  id,
  agentSessionId,
  projectId: "project",
  serverId: "test",
  harnessId: "codex",
  title: "Chat",
  origin: "codevisor",
  createdAt: "2026-01-01T00:00:00.000Z"
})

describe("workspace cleanup coordination", () => {
  it("still retires the agent when terminal cleanup fails, and propagates failure", async () => {
    const { services } = await makeServices()
    const closed = vi.spyOn(services.agents, "closeAgentSession").mockReturnValue(Effect.void)
    const terminal = services.terminal.registerExternalTerminal(
      { sessionId: "chat:background" },
      {
        stop: async () => {
          throw new Error("cleanup failed")
        },
        kill: () => {},
        write: () => {},
        resize: () => {}
      }
    )
    await expect(retireSessionRuntime(services, sessionSummary("chat", "agent"))).rejects.toThrow(
      "cleanup failed"
    )
    expect(closed).toHaveBeenCalledWith("agent")
    terminal.remove()
    const { mcp: _mcp, ...withoutMcp } = services
    await retireSessionRuntime(withoutMcp, sessionSummary("empty", ""))
    expect(closed).toHaveBeenCalledTimes(1)
    await expect(
      settleCleanup([Promise.reject(new Error("failed")), Promise.resolve()])
    ).rejects.toThrow("cleanup failed")
  })

  it("serializes worktree transitions and permits retry after failure", async () => {
    const { services } = await makeServices()
    const gate = Promise.withResolvers<void>()
    const entered = Promise.withResolvers<void>()
    const first = withWorktreeLifecycle(services, "worktree", async () => {
      entered.resolve()
      await gate.promise
      throw new Error("snapshot failed")
    })
    const failed = expect(first).rejects.toThrow("snapshot failed")
    await entered.promise
    const next = vi.fn(async () => "restored")
    const second = withWorktreeLifecycle(services, "worktree", next)
    try {
      expect(next).not.toHaveBeenCalled()
      expect(await withWorktreeLifecycle(services, "another", async () => "independent")).toBe(
        "independent"
      )
    } finally {
      gate.resolve()
      try {
        await failed
      } finally {
        await second
      }
    }
    expect(await second).toBe("restored")
  })
})
