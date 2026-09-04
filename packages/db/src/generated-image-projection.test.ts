import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("generated image transcript projection", () => {
  it("preserves completed images across replay and turn completion, ignoring incomplete and child images", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/generated-images" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const first = {
        fileId: "first-image",
        name: "first.png",
        mimeType: "image/png",
        sizeBytes: 100,
        kind: "image" as const
      }
      const second = { ...first, fileId: "second-image", name: "second.png" }
      const emit = (payload: Record<string, unknown>) =>
        run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "tool_call_update",
            kind: "image_generation",
            toolCallId: "image-tool",
            status: "completed",
            ...payload
          })
        )
      const item = async () => (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))

      for (const payload of [
        { status: "in_progress" },
        { status: "failed" },
        {},
        { rawOutput: {} },
        { rawOutput: { attachment: { name: "missing-id.png" } } },
        { rawOutput: { attachment: first }, parentToolCallId: "subagent" }
      ]) {
        await emit(payload)
        expect((await item())?.attachments).toBeUndefined()
      }

      await emit({ rawOutput: { attachment: first } })
      expect((await item())?.attachments).toEqual([first])
      await emit({ rawOutput: { attachment: first } })
      expect((await item())?.attachments).toEqual([first])
      await emit({ toolCallId: "second-tool", rawOutput: { attachment: second } })
      expect((await item())?.attachments).toEqual([first, second])
      await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "ended",
          stopReason: "end_turn"
        })
      )
      expect(await item()).toMatchObject({ attachments: [first, second], isGenerating: false })
    } finally {
      await run(db.close)
    }
  })
})
