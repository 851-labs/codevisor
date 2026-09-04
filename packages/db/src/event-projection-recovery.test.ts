import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("chat projection recovery", () => {
  it("terminalizes late output stranded after a session error", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/late-terminal-output" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "account-handoff-turn",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.error", session.id, {
        message: "Operation aborted"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { text: "The replacement completed.", type: "text" },
        messageId: "replacement-answer",
        sessionUpdate: "agent_message_chunk"
      })
    )

    const terminal = await run(
      db.appendEvent("session.updated", session.id, {
        stopDetail: "The response was recovered.",
        stopReason: "interrupted"
      })
    )
    const page = await run(db.getTranscriptPage(session.id, undefined, 8))

    expect(page.items).toMatchObject([
      { role: "assistant", isGenerating: false, stopDetail: "Operation aborted" },
      {
        role: "assistant",
        isGenerating: false,
        stopDetail: "The response was recovered.",
        text: "The replacement completed."
      }
    ])
    expect(terminal.payload).toMatchObject({ chatItemId: page.items.at(-1)?.id })
    await Effect.runPromise(db.close)
  })
})
