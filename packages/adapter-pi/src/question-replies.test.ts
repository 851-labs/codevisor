import { describe, expect, it } from "vitest"

import { definition, payloads, run, setup } from "./test-support.js"

describe("replying to Pi's dialogs", () => {
  it("fills an input with the reply and cancels a confirm, saying which got the text", async () => {
    const { provider, client, events, emit } = setup()
    const { handle } = await run(provider.createSession(definition, "/p", emit))
    client.emit(
      { type: "extension_ui_request", id: "d1", method: "input", title: "Name?" },
      { type: "extension_ui_request", id: "d2", method: "confirm", title: "Proceed?" }
    )
    const [input, confirm] = payloads(events)
      .filter((payload) => payload.sessionUpdate === "question")
      .map((payload) => String(payload.questionId))

    await expect(run(handle.replyToQuestion!(input!, { text: "Ada" }))).resolves.toBe(true)
    await expect(run(handle.replyToQuestion!(confirm!, { text: "wait" }))).resolves.toBe(false)

    expect(client.responses).toEqual([
      { id: "d1", value: "The user replied instead: Ada" },
      { id: "d2", cancelled: true }
    ])
    expect(
      payloads(events)
        .filter((payload) => payload.sessionUpdate === "question_resolved")
        .map((payload) => [payload.outcome, payload.answers])
    ).toEqual([
      ["replied", undefined],
      ["replied", undefined]
    ])
    await expect(run(handle.replyToQuestion!(input!, { text: "Ada" }))).rejects.toThrow(
      "No pending question"
    )
  })
})
