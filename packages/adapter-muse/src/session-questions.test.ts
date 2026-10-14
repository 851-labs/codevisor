import { describe, expect, it } from "vitest"

import { payloads, send, startChat as start } from "./test-support.js"

describe("Muse chat questions", () => {
  it("asks Muse's approvals and questions, and sends the answers back", async () => {
    const { client, chat, events } = await start()
    const { finished, turnId: deploy } = await send(chat, client, "deploy")
    const choices = [
      { choiceId: "allow_once", label: "Allow once", decision: "approved" },
      { choiceId: "abort", label: "Stop", decision: "abort" }
    ]
    const approval = {
      approvalId: "ap-1",
      toolName: "bash",
      toolCallId: "c",
      rawArgs: "{}",
      subject: { kind: "shell", command: "deploy.sh" },
      currentRequirementId: { approvalId: "ap-1", sourceIndex: 0 },
      availableChoices: choices
    }
    expect(client.serverRequest("approval/request", approval)).toEqual({})
    client.serverRequest("approval/request", {
      ...approval,
      currentRequirementId: { approvalId: "ap-1", sourceIndex: 1 }
    })
    expect(
      payloads(events).filter((payload) => String(payload.sessionUpdate).startsWith("question"))
    ).toEqual([
      expect.objectContaining({ sessionUpdate: "question", questionId: "ap-1" }),
      expect.objectContaining({
        sessionUpdate: "question_resolved",
        questionId: "ap-1",
        outcome: "autoResolved"
      }),
      expect.objectContaining({ sessionUpdate: "question", questionId: "ap-1" })
    ])
    await chat.answerQuestion("ap-1", {
      outcome: "answered",
      answers: { permission: { answers: ["Allow once"] } }
    })
    expect(client.sent("approval/decide")[0]).toMatchObject({
      approvalId: "ap-1",
      requirementId: { approvalId: "ap-1", sourceIndex: 1 },
      choiceId: "allow_once"
    })
    expect(payloads(events).at(-1)).toMatchObject({
      sessionUpdate: "question_resolved",
      outcome: "answered",
      answers: { permission: { answers: ["Allow once"] } }
    })
    await expect(chat.answerQuestion("ap-1", { outcome: "cancelled" })).rejects.toThrow(
      "No pending question: ap-1"
    )

    client.serverRequest("userInput/request", {
      userInputId: "ui-1",
      autoResolutionMs: 1000,
      questions: [
        {
          id: "q",
          header: "",
          question: "Which?",
          options: [{ label: "A" }],
          selection: { mode: "single" }
        }
      ]
    })
    expect(payloads(events).at(-1)).toMatchObject({
      sessionUpdate: "question",
      questionId: "ui-1",
      autoResolutionMs: 1000
    })
    client.emit("userInput/settled", { userInputId: "ui-1" })
    client.emit("userInput/settled", { userInputId: "ui-1" })
    client.emit("approval/resolved", { approvalId: 7 })
    expect(payloads(events).at(-1)).toMatchObject({
      sessionUpdate: "question_resolved",
      questionId: "ui-1",
      outcome: "autoResolved"
    })
    expect(client.serverRequest("session/unknownRequest", {})).toEqual({})

    client.serverRequest("approval/request", { ...approval, approvalId: "ap-2" })
    client.emit("approval/resolved", { approvalId: "other" })
    client.emit("turn/completed", { turnId: deploy, terminal: "completed" })
    await finished
    expect(payloads(events).findLast((payload) => payload.questionId === "ap-2")).toMatchObject({
      sessionUpdate: "question_resolved",
      outcome: "cancelled"
    })
  })

  it("keeps a question open when Muse doesn't take the answer", async () => {
    const { client, chat } = await start()
    client.serverRequest("userInput/request", {
      userInputId: "ui-9",
      questions: [
        { id: "q", header: "", question: "Which?", options: [], selection: { mode: "single" } }
      ]
    })
    client.replies["userInput/answer"] = new Error("backpressured")
    const answer = { outcome: "answered" as const, answers: { q: { answers: ["A"] } } }
    await expect(chat.answerQuestion("ui-9", answer)).rejects.toThrow("backpressured")
    client.replies["userInput/answer"] = {}
    await chat.answerQuestion("ui-9", answer)
    expect(client.sent("userInput/answer")).toHaveLength(2)
  })
})
