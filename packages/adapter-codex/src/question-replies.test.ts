import { SKIPPED_FOR_REPLY, type PromptInput, type RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { payloadField, payloadOf, run, setup, stringOf } from "./test-support.js"

type Context = Awaited<ReturnType<typeof setup>>

const askUserInput = async ({ client, nextEvent }: Context) => {
  const asked = nextEvent(isQuestion)
  const request = client.serverRequest("item/tool/requestUserInput", {
    itemId: "item-q1",
    questions: [
      { id: "approach", isOther: true, options: [{ label: "MVP" }], question: "Which approach?" },
      { id: "scope", isOther: true, options: [], question: "What scope?" }
    ],
    threadId: "thread-new",
    turnId: "turn-1"
  })
  await asked
  return { request }
}

const askApproval = async ({ client, nextEvent }: Context) => {
  const asked = nextEvent(isQuestion)
  const request = client.serverRequest("item/commandExecution/requestApproval", {
    itemId: "cmd-1",
    threadId: "thread-new",
    turnId: "turn-1"
  })
  await asked
  return { request }
}

const askElicitation = async ({ client, nextEvent }: Context) => {
  const asked = nextEvent(isQuestion)
  const request = client.serverRequest("mcpServer/elicitation/request", {
    message: "Pick one.",
    mode: "form",
    requestedSchema: {
      properties: { choice: { enum: ["a", "b"], type: "string" } },
      type: "object"
    },
    serverName: "svc",
    threadId: "thread-new",
    turnId: null
  })
  await asked
  return { request }
}

const reply = async (context: Context, input: PromptInput): Promise<boolean> => {
  const questionId = stringOf(payloadOf(context.events.at(-1)).questionId)
  return run(context.created!.handle.replyToQuestion!(questionId, input))
}

describe("Codex question replies", () => {
  it("answers the first requestUserInput question with the typed reply and skips the rest", async () => {
    const context = await setup()
    const { request } = await askUserInput(context)

    await expect(reply(context, { text: " Ship the MVP " })).resolves.toBe(true)

    await expect(request).resolves.toEqual({
      answers: {
        approach: { answers: ["The user replied instead: Ship the MVP"] },
        scope: { answers: [SKIPPED_FOR_REPLY] }
      }
    })
    expect(payloadOf(context.events.at(-1))).toEqual({
      outcome: "replied",
      questionId: "item-q1",
      questions: expect.any(Array),
      sessionUpdate: "question_resolved"
    })
  })

  it("answers requestUserInput neutrally when the reply has attachments", async () => {
    const context = await setup()
    const { request } = await askUserInput(context)

    await expect(
      reply(context, {
        attachments: [
          {
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/shot.png",
            sizeBytes: 2
          }
        ],
        text: "Look at this"
      })
    ).resolves.toBe(false)

    await expect(request).resolves.toEqual({
      answers: {
        approach: { answers: ["The user replied instead of answering."] },
        scope: { answers: [SKIPPED_FOR_REPLY] }
      }
    })
    expect(payloadOf(context.events.at(-1))).toMatchObject({ outcome: "replied" })
  })

  it.each([
    { ask: askApproval, kind: "approvals", response: { decision: "decline" } },
    {
      ask: askElicitation,
      kind: "MCP elicitations",
      response: { action: "decline", content: null }
    }
  ])("declines $kind without carrying the reply", async ({ ask, response }) => {
    const context = await setup()
    const { request } = await ask(context)

    await expect(reply(context, { text: "Use the staging database" })).resolves.toBe(false)

    await expect(request).resolves.toEqual(response)
    expect(payloadOf(context.events.at(-1))).toMatchObject({
      outcome: "replied",
      sessionUpdate: "question_resolved"
    })
    expect(payloadOf(context.events.at(-1))).not.toHaveProperty("answers")
  })

  it("rejects replies to questions that are not pending", async () => {
    const { created } = await setup()
    await expect(
      run(created!.handle.replyToQuestion!("missing", { text: "hello" }))
    ).rejects.toThrow("No pending question")
  })
})

const isQuestion = (event: RuntimeEvent): boolean =>
  event.kind === "session.output" && payloadField(event, "sessionUpdate") === "question"
