import { expect, it } from "vitest"

import { memoryDatabase, run } from "./test-support.js"
import { asksInTranscript, splitsWorkedSection } from "./transcript-questions.js"

const questions = [
  {
    id: "db",
    header: "Database",
    question: "Which database?",
    options: [{ label: "Postgres" }, { label: "SQLite" }],
    allowsOther: true
  },
  { id: "tests", question: "Add tests?", options: [{ label: "Yes" }], allowsOther: true }
]

const askedSession = async () => {
  const context = await memoryDatabase()
  const { db, session } = context
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "agent_message_chunk",
      messageId: "before",
      content: { type: "text", text: "Two questions first." }
    })
  )
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "question",
      questionId: "q",
      message: "Before I start",
      questions
    })
  )
  return context
}

const resolve = async (
  context: Awaited<ReturnType<typeof memoryDatabase>>,
  resolution: Record<string, unknown>
) =>
  run(
    context.db.appendEvent("session.output", context.session.id, {
      sessionUpdate: "question_resolved",
      questionId: "q",
      questions,
      ...resolution
    })
  )

const page = async (context: Awaited<ReturnType<typeof memoryDatabase>>) =>
  run(context.db.getTranscriptPage(context.session.id, undefined, 8))

it("ends the worked section at a question and keeps it pending on the turn", async () => {
  const context = await askedSession()

  const asked = await page(context)

  expect(asked.pendingQuestion?.questionId).toBe("q")
  expect(asked.items).toHaveLength(1)
  expect(asked.items[0]).toMatchObject({
    isGenerating: false,
    interactions: [{ id: "q", kind: "question", payload: { message: "Before I start", questions } }]
  })
  expect(asked.items[0]?.interactions?.[0]?.answer).toBeUndefined()
})

it("records the answers and resumes work in a new section", async () => {
  const context = await askedSession()
  const answers = { db: { answers: ["Postgres"] }, tests: { answers: [], note: "Only unit" } }

  const resolved = await resolve(context, { outcome: "answered", answers })
  const after = await page(context)

  expect(after.items).toHaveLength(2)
  expect(after.items[0]?.interactions).toEqual([
    {
      id: "q",
      kind: "question",
      payload: { message: "Before I start", questions },
      answer: { outcome: "answered", answers }
    }
  ])
  expect(after.items[1]).toMatchObject({ isGenerating: true })
  expect(resolved.payload).toMatchObject({ assistantItemId: after.items[1]?.id })
})

it("puts a reply sent instead of answering between the question and the resumed work", async () => {
  const context = await askedSession()
  await run(
    context.db.appendEvent("session.output", context.session.id, {
      role: "user",
      messageId: "reply",
      text: "Use whatever you think"
    })
  )

  await resolve(context, { outcome: "replied" })
  const after = await page(context)

  expect(after.items.map((item) => [item.role, item.isGenerating])).toEqual([
    ["assistant", false],
    ["user", false],
    ["assistant", true]
  ])
  expect(after.items[0]?.interactions?.[0]?.answer).toEqual({ outcome: "replied" })
  expect(after.pendingQuestion).toBeUndefined()
})

it("reads a question abandoned by the end of its turn as dismissed", async () => {
  const context = await askedSession()
  await run(context.db.appendEvent("session.updated", context.session.id, { turnState: "ended" }))

  const after = await page(context)

  expect(after.items[0]?.interactions?.[0]?.answer).toEqual({ outcome: "cancelled" })
})

it("skips question entries it can't read and keeps a resolution without its prompt", async () => {
  const context = await memoryDatabase()
  const { db, session } = context
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "question",
      questionId: "broken",
      questions: [{ id: "x" }]
    })
  )
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "question_resolved",
      questionId: "late",
      outcome: "answered",
      questions,
      answers: { db: "Postgres" }
    })
  )

  const after = await page(context)

  expect(after.items.flatMap((item) => item.interactions ?? [])).toEqual([
    { id: "late", kind: "question", payload: { questions }, answer: { outcome: "answered" } }
  ])
})

it("asks in the transcript unless the prompt is a setup request or a plan approval", () => {
  const setup = [{ id: "cu", presentation: "computerUsePermissions" }]
  const plan = [{ id: "exit_plan_mode" }]

  expect(asksInTranscript({ questions })).toBe(true)
  expect(asksInTranscript({ questions: setup })).toBe(false)
  expect(asksInTranscript({ questions: plan })).toBe(false)
  expect(asksInTranscript({ questions: [] })).toBe(false)
  expect(asksInTranscript(undefined)).toBe(false)
  expect(splitsWorkedSection({ questions: setup })).toBe(true)
  expect(splitsWorkedSection({ questions: plan })).toBe(false)
})
