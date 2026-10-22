import { describe, expect, it } from "vitest"

import { setup } from "./test-support.js"

describe("Codex notification updates", () => {
  it("streams reasoning text and summaries as thought chunks", async () => {
    const { client, events } = await setup()
    client.emit("item/reasoning/textDelta", {
      delta: "Checking the build",
      itemId: "rs_1",
      threadId: "thread-new"
    })
    client.emit("item/reasoning/summaryTextDelta", { itemId: "rs_1", threadId: "thread-new" })
    expect(events.map((event) => event.payload)).toEqual([
      {
        content: { text: "Checking the build", type: "text" },
        sessionUpdate: "agent_thought_chunk"
      },
      { content: { text: "", type: "text" }, sessionUpdate: "agent_thought_chunk" }
    ])
  })

  it("reports Codex plan updates as plan entries and skips malformed steps", async () => {
    const { client, events } = await setup()
    client.emit("turn/plan/updated", {
      plan: [
        { status: "completed", step: "Read the code" },
        { status: "inProgress", step: "Write the fix" },
        "junk",
        { status: "blocked" }
      ],
      threadId: "thread-new"
    })
    expect(events.at(-1)?.payload).toEqual({
      entries: [
        { content: "Read the code", priority: "medium", status: "completed" },
        { content: "Write the fix", priority: "medium", status: "in_progress" },
        { content: "", priority: "medium", status: "pending" }
      ],
      sessionUpdate: "plan"
    })
  })
})
