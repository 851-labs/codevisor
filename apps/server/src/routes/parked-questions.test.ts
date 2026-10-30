import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TranscriptPage } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { updateResumeNotice } from "../restart-notice.js"
import { pauseForUpdate, restartStatePaths } from "../restart-test-support.js"
import type { RunningCodevisorServer } from "../server.js"
import { askedQuestion, planApproval } from "../test-support-questions.js"
import {
  bodyId,
  jsonRequest,
  listSubjectEvents,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { field } from "../unknown-values.js"
import { buildModeId, parkedAnswerPrompt } from "./parked-questions.js"

const openSession = async (server: RunningCodevisorServer, folderName: string): Promise<string> => {
  const folder = join(mkdtempSync(join(tmpdir(), "codevisor-parked-")), folderName)
  tempDirs.push(folder)
  mkdirSync(folder, { recursive: true })
  const projectId = bodyId(
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
  )
  return bodyId(
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ harnessId: "codex", projectId, title: "Asking" }),
      method: "POST"
    })
  )
}

const prompt = (server: RunningCodevisorServer, sessionId: string, text: string) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
    body: JSON.stringify({ text }),
    method: "POST"
  })

const answer = (
  server: RunningCodevisorServer,
  sessionId: string,
  body: unknown,
  questionId = askedQuestion.questionId
) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/questions/${questionId}/answer`, {
    body: JSON.stringify(body),
    method: "POST"
  })

const transcript = async (server: RunningCodevisorServer, sessionId: string) =>
  Schema.decodeUnknownSync(TranscriptPage)(
    (await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body
  )

const questionOutcomes = (services: Parameters<typeof listSubjectEvents>[0], sessionId: string) =>
  listSubjectEvents(services, sessionId)
    .map((event) => event.payload)
    .filter((payload) => field(payload, "sessionUpdate") === "question_resolved")
    .map((payload) => field(payload, "outcome"))

const runningTask = { id: "dev", description: "Dev server", status: "running", taskType: "shell" }

const restartedWithParkedQuestion = async (
  options: { readonly withTask?: boolean; readonly plan?: boolean } = {}
) => {
  const { agents, services } = await makeServices("server-a")
  const paths = restartStatePaths()
  const server = await startWithApp(services, undefined, paths)
  const plan = options.plan === true
  const sessionId = await openSession(server, plan ? "plan-modes" : "repo")
  const asking = plan ? "plan until cancelled" : "ask until cancelled"
  expect((await prompt(server, sessionId, asking)).status).toBe(202)
  await waitFor(async () => (await transcript(server, sessionId)).pendingQuestion !== undefined)
  if (options.withTask === true) {
    await run(
      services.db.appendEvent("session.updated", sessionId, { backgroundTasks: [runningTask] })
    )
  }

  await pauseForUpdate(server)
  await run(server.close)
  const restarted = await startWithApp(services, undefined, paths)
  await waitFor(() => !existsSync(paths.pausedTurnsPath))
  return { agents, services, restarted, sessionId }
}

const answered = {
  outcome: "answered",
  answers: { db: { answers: ["Postgres"], note: "with pgvector" } }
} as const

describe("questions parked by an update restart", () => {
  it("keeps the question waiting instead of dismissing it or continuing the agent", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion()

    const page = await transcript(restarted, sessionId)

    expect(page.pendingQuestion?.questionId).toBe(askedQuestion.questionId)
    expect(page.items.at(-1)).toMatchObject({ stopKind: "pausedForUpdate" })
    expect(page.items.at(-1)?.interactions?.[0]?.answer).toBeUndefined()
    expect(questionOutcomes(services, sessionId)).toEqual([])
    expect(agents.prompts.map(([, input]) => input)).toEqual(["ask until cancelled"])
  })

  it("records the answer and resumes the agent with a message carrying it", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion()

    expect((await answer(restarted, sessionId, answered)).status).toBe(202)
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.prompts[1]?.[1]).toBe(
      parkedAnswerPrompt({ sessionUpdate: "question", ...askedQuestion }, answered)
    )
    expect(agents.prompts[1]?.[1]).toContain("- Which database? → Postgres — with pgvector")
    expect(agents.questionAnswers).toEqual([])
    expect(questionOutcomes(services, sessionId)).toEqual(["answered"])
    const page = await transcript(restarted, sessionId)
    expect(page.pendingQuestion).toBeUndefined()
    expect(page.items.flatMap((item) => item.interactions ?? [])).toEqual([
      expect.objectContaining({ answer: { outcome: "answered", answers: answered.answers } })
    ])
  })

  it("tells the agent when the user dismisses it", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion()

    await answer(restarted, sessionId, { outcome: "cancelled" })
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.prompts[1]?.[1]).toContain("The user has now dismissed it without answering.")
    expect(questionOutcomes(services, sessionId)).toEqual(["cancelled"])
  })

  it("holds the restart notice until the answer, then sends it after the answer", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion({
      withTask: true
    })
    await waitFor(async () => (await run(services.db.listPromptQueue(sessionId))).length === 1)

    await answer(restarted, sessionId, answered)
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.prompts[1]?.[1]).toBe(
      [
        parkedAnswerPrompt({ sessionUpdate: "question", ...askedQuestion }, answered),
        updateResumeNotice(["Dev server"])
      ].join("\n\n")
    )
  })

  it("resolves it as replied when the user sends a message instead", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion()

    await prompt(restarted, sessionId, "use whatever you like")
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.prompts[1]?.[1]).toBe("use whatever you like")
    expect(questionOutcomes(services, sessionId)).toEqual(["replied"])
    expect((await transcript(restarted, sessionId)).pendingQuestion).toBeUndefined()
  })

  it("switches out of plan mode before telling the agent its approved plan can start", async () => {
    const { agents, services, restarted, sessionId } = await restartedWithParkedQuestion({
      plan: true
    })

    await answer(
      restarted,
      sessionId,
      { outcome: "answered", answers: { exit_plan_mode: { answers: ["Implement plan"] } } },
      planApproval.questionId
    )
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.modes.map(([, modeId]) => modeId)).toEqual(["bypassPermissions"])
    expect(agents.prompts[1]?.[1]).toContain(
      "The user approved your plan and plan mode is now off."
    )
    const payloads = listSubjectEvents(services, sessionId).map((event) => event.payload)
    const switched = payloads.findIndex(
      (payload) => field(payload, "modeId") === "bypassPermissions"
    )
    const delivered = payloads.findIndex((payload) =>
      String(field(payload, "text")).includes("question.answered")
    )
    expect(switched).toBeGreaterThan(-1)
    expect(switched).toBeLessThan(delivered)
  })

  it("stays in plan mode and sends the rejection when the user keeps planning", async () => {
    const { agents, restarted, sessionId } = await restartedWithParkedQuestion({ plan: true })

    await answer(
      restarted,
      sessionId,
      {
        outcome: "answered",
        answers: { exit_plan_mode: { answers: ["Keep planning"], note: "Split the migration" } }
      },
      planApproval.questionId
    )
    await waitFor(() => agents.prompts.length === 2)

    expect(agents.modes).toEqual([])
    expect(agents.prompts[1]?.[1]).toContain(
      "- Ready to implement this plan? → Keep planning — Split the migration"
    )
  })

  it("leaves plan mode for the first non-plan mode when there is no full access mode", () => {
    const modes = {
      currentModeId: "plan",
      availableModes: [
        { id: "plan", name: "Plan" },
        { id: "ask", name: "Ask", canonicalId: "ask" as const }
      ]
    }

    expect(buildModeId(modes)).toBe("ask")
    expect(buildModeId({ ...modes, currentModeId: "ask" })).toBeUndefined()
    expect(buildModeId(undefined)).toBeUndefined()
    expect(
      parkedAnswerPrompt(
        {
          sessionUpdate: "question",
          questionId: "grok",
          questions: [{ ...planApproval.questions[0]!, id: "grok_exit_plan_mode" }]
        },
        { outcome: "answered", answers: { grok_exit_plan_mode: { answers: ["Abandon plan"] } } }
      )
    ).toContain("The user chose to leave plan mode without implementing the plan.")
  })
})
