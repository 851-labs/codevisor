import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("plan section timestamps", () => {
  it("records when a plan was proposed and when the same turn resumed after it", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/plan-timing" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
    const latest = async () =>
      (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)
    const planQuestion = [{ id: "exit_plan_mode", question: "Ready?", options: [] }]
    const resolve = (questionId: string) =>
      run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question_resolved",
          outcome: "answered",
          questionId,
          questions: planQuestion,
          answers: { exit_plan_mode: { answers: ["Implement plan"] } }
        })
      )

    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    // An answer before any plan exists is not a plan boundary.
    await resolve("before-plan")
    expect(await latest()).not.toHaveProperty("planResumedAt")

    const firstPlan = await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "plan_document",
        markdown: "1. draft"
      })
    )
    expect(await latest()).toMatchObject({ planProposedAt: firstPlan.createdAt })
    expect(await latest()).not.toHaveProperty("planResumedAt")

    const declined = await resolve("keep-planning")
    expect(await latest()).toMatchObject({ planResumedAt: declined.createdAt })
    // Later answers in the resumed work do not move the boundary.
    await resolve("tool-permission")
    expect(await latest()).toMatchObject({ planResumedAt: declined.createdAt })

    // A revised plan replaces the boundary and awaits a fresh answer.
    const revised = await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "plan_document",
        markdown: "1. final"
      })
    )
    expect(await latest()).toMatchObject({ planProposedAt: revised.createdAt })
    expect(await latest()).not.toHaveProperty("planResumedAt")
    const approved = await resolve("implement")
    expect(await latest()).toMatchObject({
      planProposedAt: revised.createdAt,
      planResumedAt: approved.createdAt
    })
    await Effect.runPromise(db.close)
  })
})
