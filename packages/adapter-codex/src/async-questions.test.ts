import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { payloadField, payloadOf, recordOf, run, setup } from "./test-support.js"

const ARENA_ID = '["request_user_input_async","call-1",0]'
const PLATFORM_ID = '["request_user_input_async","call-2",0]'

const asyncMessage = (id: string, questions: ReadonlyArray<Record<string, unknown>>) => ({
  delivery: "async",
  id,
  phase: "final_answer",
  questions,
  text: questions.map((question) => question.title).join("\n\n"),
  type: "agentMessage"
})

const deliverAsyncMessage = (
  client: Awaited<ReturnType<typeof setup>>["client"],
  item: Record<string, unknown>
): void => {
  client.emit("item/started", { item, threadId: "thread-new", turnId: "turn-1" })
  client.emit("item/completed", { item, threadId: "thread-new", turnId: "turn-1" })
}

const startTurn = async () => {
  const context = await setup()
  const { client, created, nextEvent } = context
  const turnRequested = client.nextRequest("turn/start")
  const prompt = run(created!.handle.prompt("build a multiplayer shooter"))
  await turnRequested
  const started = nextEvent(isTurnState("started"))
  client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-1" } })
  await started
  deliverAsyncMessage(
    client,
    asyncMessage("call-1", [{ options: ["Arena", "Battlefield"], title: "What kind of shooter?" }])
  )
  return { ...context, handle: created!.handle, prompt }
}

const completeTurn = (
  client: Awaited<ReturnType<typeof setup>>["client"],
  id: string,
  status = "completed"
): void => {
  client.emit("turn/completed", { threadId: "thread-new", turn: { id, status } })
}

const isTurnState =
  (state: string) =>
  (event: RuntimeEvent): boolean =>
    event.kind === "session.updated" && payloadField(event, "turnState") === state

const questionEvents = (events: ReadonlyArray<RuntimeEvent>, update: string) =>
  events.filter((event) => payloadField(event, "sessionUpdate") === update).map(payloadOf)

describe("Codex asynchronous questions", () => {
  it("asks request_user_input_async questions as one card and answers them in the same turn", async () => {
    const { client, events, handle, prompt } = await startTurn()
    deliverAsyncMessage(client, asyncMessage("call-2", [{ title: "Which platform?\nPick one." }]))

    expect(questionEvents(events, "question").at(-1)).toEqual({
      questionId: "call-1",
      questions: [
        {
          allowsOther: true,
          id: ARENA_ID,
          options: [{ label: "Arena" }, { label: "Battlefield" }],
          question: "What kind of shooter?"
        },
        { allowsOther: true, id: PLATFORM_ID, options: [], question: "Which platform?\nPick one." }
      ],
      sessionUpdate: "question"
    })
    expect(
      events.some((event) => payloadField(event, "sessionUpdate") === "agent_message_chunk")
    ).toBe(false)

    completeTurn(client, "turn-1")
    expect(events.some(isTurnState("ended"))).toBe(false)

    const continued = client.nextRequest("turn/start")
    await run(
      handle.answerQuestion!("call-1", {
        answers: {
          [ARENA_ID]: { answers: ["Arena"] },
          [PLATFORM_ID]: { answers: [], note: "Web browser" }
        },
        outcome: "answered"
      })
    )
    await continued
    expect(recordOf(client.requests.at(-1)?.params)).toMatchObject({
      input: [
        {
          text: '<send_user_message_question_reply>\n[{"answer":"Arena","question":"What kind of shooter?","questionItemId":"[\\"request_user_input_async\\",\\"call-1\\",0]"},{"answer":"Web browser","question":"Which platform? Pick one.","questionItemId":"[\\"request_user_input_async\\",\\"call-2\\",0]"}]\n</send_user_message_question_reply>',
          type: "text"
        }
      ],
      model: "gpt-5.2-codex",
      threadId: "thread-new"
    })
    expect(questionEvents(events, "question_resolved").at(-1)).toMatchObject({
      outcome: "answered",
      questionId: "call-1"
    })

    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-2" } })
    completeTurn(client, "turn-2")
    await expect(prompt).resolves.toEqual({ stopReason: "end_turn" })
    expect(
      events.filter(isTurnState("started")).map((event) => payloadField(event, "turnId"))
    ).toEqual(["turn-1"])
    expect(
      events.filter(isTurnState("ended")).map((event) => payloadField(event, "turnId"))
    ).toEqual(["turn-1"])
  })

  it.each([
    {
      action: "an answer",
      answer: {
        answers: { [ARENA_ID]: { answers: ["Battlefield"], note: "with vehicles" } },
        outcome: "answered" as const
      },
      outcome: "answered",
      reply: "Battlefield — with vehicles"
    },
    {
      action: "a dismissal",
      answer: { outcome: "cancelled" as const },
      outcome: "cancelled",
      reply: "The user dismissed this question without answering."
    }
  ])(
    "steers $action into the Codex turn that is still running",
    async ({ answer, outcome, reply }) => {
      const { client, events, handle, prompt } = await startTurn()
      const steered = client.nextRequest("turn/steer")
      await run(handle.answerQuestion!("call-1", answer))
      await steered
      expect(client.requests.at(-1)).toMatchObject({
        method: "turn/steer",
        params: {
          expectedTurnId: "turn-1",
          input: [
            {
              text: `<send_user_message_question_reply>\n[{"answer":"${reply}","question":"What kind of shooter?","questionItemId":"[\\"request_user_input_async\\",\\"call-1\\",0]"}]\n</send_user_message_question_reply>`,
              type: "text"
            }
          ]
        }
      })
      expect(questionEvents(events, "question_resolved").at(-1)).toMatchObject({
        outcome,
        questionId: "call-1"
      })
      completeTurn(client, "turn-1")
      await expect(prompt).resolves.toEqual({ stopReason: "end_turn" })
    }
  )

  it.each([
    {
      action: "dismissing the card",
      stopReason: "end_turn",
      stop: (handle: Awaited<ReturnType<typeof startTurn>>["handle"]) =>
        run(handle.answerQuestion!("call-1", { outcome: "cancelled" }))
    },
    {
      action: "cancelling the session",
      stopReason: "cancelled",
      stop: (handle: Awaited<ReturnType<typeof startTurn>>["handle"]) => run(handle.cancel)
    }
  ])("ends the held turn by $action", async ({ stop, stopReason }) => {
    const { client, events, handle, prompt } = await startTurn()
    completeTurn(client, "turn-1")
    await stop(handle)
    await expect(prompt).resolves.toEqual({ stopReason })
    expect(questionEvents(events, "question_resolved").at(-1)).toMatchObject({
      outcome: "cancelled",
      questionId: "call-1"
    })
    expect(client.requests.filter((request) => request.method === "turn/start")).toHaveLength(1)
    expect(client.requests.some((request) => request.method === "turn/interrupt")).toBe(false)
    expect(
      events.filter(isTurnState("ended")).map((event) => payloadField(event, "turnId"))
    ).toEqual(["turn-1"])
  })

  it("continues the held turn with a message typed instead of an answer", async () => {
    const { client, events, handle } = await startTurn()
    completeTurn(client, "turn-1")
    await expect(run(handle.steer!("Let's do a battle royale instead"))).resolves.toBe(true)
    expect(client.requests.at(-1)).toMatchObject({
      method: "turn/start",
      params: { input: [{ text: "Let's do a battle royale instead", type: "text" }] }
    })
    expect(questionEvents(events, "question_resolved").at(-1)).toMatchObject({
      outcome: "cancelled",
      questionId: "call-1"
    })
  })

  it("shows free-form asynchronous messages, which arrive without text deltas", async () => {
    const { client, events } = await setup()
    deliverAsyncMessage(client, {
      delivery: "async",
      id: "call-note",
      phase: "final_answer",
      questions: null,
      text: "The build is still running; I'll report back.",
      type: "agentMessage"
    })
    expect(questionEvents(events, "agent_message_chunk")).toEqual([
      {
        content: { text: "The build is still running; I'll report back.", type: "text" },
        messageId: "call-note",
        phase: "final",
        sessionUpdate: "agent_message_chunk"
      }
    ])
  })
})
