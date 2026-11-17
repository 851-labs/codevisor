import type { EventEnvelope, EventKind } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeRuntimeAccountFollower } from "./runtime-account-follower.js"

const fixture = () => {
  const stale = new Map<string, ReadonlyArray<string>>()
  const busy = new Set<string>()
  const restarted: Array<string> = []
  const follower = makeRuntimeAccountFollower({
    staleChats: async (harnessId) => stale.get(harnessId) ?? [],
    isBusy: async (chatId) => busy.has(chatId),
    restart: async (chatId) => {
      restarted.push(chatId)
    }
  })
  return { stale, busy, restarted, follower }
}

const event = (kind: EventKind, subjectId: string, payload: unknown = {}): EventEnvelope => ({
  id: 1,
  serverId: "server-a",
  kind,
  subjectId,
  createdAt: "2026-11-16T17:24:54.000Z",
  payload
})

const accountsChanged = (harnessId: string) => event("harness.auth.updated", harnessId)

const turnEnded = (chatId: string) =>
  event("session.updated", chatId, { turnState: "ended", stopReason: "end_turn" })

describe("runtime account follower", () => {
  it("restarts idle chats on the new account as soon as the account changes", async () => {
    const { stale, restarted, follower } = fixture()
    stale.set("claude-code", ["idle-a", "idle-b"])
    stale.set("codex", ["codex-chat"])

    await follower.handle(accountsChanged("claude-code"))

    expect(restarted).toEqual(["idle-a", "idle-b"])
  })

  it("waits for a busy chat to finish its turn, including a wake-up turn after its background task", async () => {
    const { stale, busy, restarted, follower } = fixture()
    stale.set("claude-code", ["working", "idle"])
    busy.add("working")

    await follower.handle(accountsChanged("claude-code"))
    expect(restarted).toEqual(["idle"])

    await follower.handle(turnEnded("working"))
    await follower.handle(event("session.updated", "working", { backgroundTasks: [] }))
    expect(restarted).toEqual(["idle"])

    busy.delete("working")
    await follower.handle(event("session.updated", "working", { turnState: "started" }))
    expect(restarted).toEqual(["idle"])

    await follower.handle(turnEnded("working"))
    await follower.handle(turnEnded("working"))
    expect(restarted).toEqual(["idle", "working"])
  })

  it("restarts a busy chat whose turn ends in an error", async () => {
    const { stale, busy, restarted, follower } = fixture()
    stale.set("claude-code", ["working"])
    busy.add("working")
    await follower.handle(accountsChanged("claude-code"))
    busy.delete("working")

    await follower.handle(turnEnded("unrelated"))
    await follower.handle(event("session.error", "working", { message: "API Error" }))

    expect(restarted).toEqual(["working"])
  })
})
