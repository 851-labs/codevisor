import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run } from "./test-support.js"

const agentCallFixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/agent-calls" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
  const turn = (turnState: "started" | "ended") =>
    run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState,
        ...(turnState === "ended" ? { stopReason: "end_turn" } : {})
      })
    )
  const execute = (toolCallId: string, code: string, status = "in_progress") =>
    run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId,
        title: "mcp__codevisor__execute",
        status,
        rawInput: { code }
      })
    )
  return {
    turn,
    execute,
    talkingToAgent: async () =>
      (await run(db.getSessionSummary(session.id))).talkingToAgent === true
  }
}

describe("agent calls in flight", () => {
  it("flags a chat only while one of its tool calls is talking to an agent", async () => {
    const chat = await agentCallFixture()
    await chat.turn("started")

    await chat.execute("send", 'await machines.current.tools["codevisor.messages.send"]({ text })')
    expect(await chat.talkingToAgent()).toBe(false)

    await chat.execute("message", "await machines.current.agents.message({ agentId, text })")
    await chat.execute("wait", "return await machines.current.agents.wait({ agentIds })")
    expect(await chat.talkingToAgent()).toBe(true)

    await chat.execute("message", "", "completed")
    expect(await chat.talkingToAgent()).toBe(true)

    await chat.execute("wait", "", "failed")
    expect(await chat.talkingToAgent()).toBe(false)
  })

  it("drops calls a turn left unsettled when the turn ends", async () => {
    const chat = await agentCallFixture()
    await chat.turn("started")
    await chat.execute("start", "await machines.current.agents.start({ text })")
    expect(await chat.talkingToAgent()).toBe(true)

    await chat.turn("ended")
    expect(await chat.talkingToAgent()).toBe(false)
  })
})
