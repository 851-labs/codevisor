import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  run,
  startTestSession,
  stringValue,
  toolCheck
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("refuses a permission mode Claude does not have", async () => {
    const fake = new FakeQuery()
    const createPromise = run(makeProvider(fake).createSession(definition, "/tmp", async () => {}))
    fake.push(initMessage())
    const created = await createPromise
    await expect(run(created.handle.setMode("yolo"))).rejects.toThrow("Unknown mode: yolo")
    expect(fake.permissionModes).toEqual([])
  })

  it("surfaces tool approvals as Allow/Deny questions in ask modes", async () => {
    const { fake, events, created } = await startTestSession()
    await run(created.handle.setMode("default"))
    expect(fake.permissionModes).toEqual(["default"])

    const toolInput = { command: "rm -rf build" }
    const decision = fake.options!.canUseTool!("Bash", toolInput, toolCheck())
    await fake.drain()
    const asked = payloadOf(events.at(-1))
    expect(asked).toMatchObject({ sessionUpdate: "question" })
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Permission",
        id: "approval",
        options: [{ label: "Allow" }, { label: "Deny" }],
        question: "Allow Bash?"
      }
    ])
    await run(
      created.handle.answerQuestion!(stringValue(asked.questionId), {
        answers: { approval: { answers: ["Allow"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    const denied = fake.options!.canUseTool!("Edit", { file_path: "/tmp/a" }, toolCheck())
    await fake.drain()
    const deniedAsk = payloadOf(events.at(-1))
    await run(
      created.handle.answerQuestion!(stringValue(deniedAsk.questionId), {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(denied).resolves.toEqual({
      behavior: "deny",
      message: "User denied permission."
    })
  })

  it("auto-allows checks the CLI escalates while in bypassPermissions", async () => {
    const { fake, events, created } = await startTestSession()
    using log = vi.spyOn(console, "error").mockImplementation(() => {})

    expect(fake.options?.allowDangerouslySkipPermissions).toBe(true)
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")

    const toolInput = { command: 'for f in a b; do grep -n "$f" .; done' }
    const eventsBefore = events.length
    await expect(
      fake.options!.canUseTool!("Bash", toolInput, {
        ...toolCheck(),
        agentID: "a120e6ad",
        decisionReason: "variable loop cannot be statically validated"
      })
    ).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })
    expect(events.length).toBe(eventsBefore)
    expect(log).toHaveBeenCalledWith(expect.stringContaining("agent=a120e6ad"))
    expect(log).toHaveBeenCalledWith(expect.stringContaining("variable loop"))

    const question = fake.options!.canUseTool!(
      "AskUserQuestion",
      { questions: [{ header: "Scope", question: "Which?", options: [{ label: "A" }] }] },
      toolCheck()
    )
    await fake.drain()
    expect(payloadOf(events.at(-1)).sessionUpdate).toBe("question")
    await run(
      created.handle.answerQuestion!(stringValue(payloadOf(events.at(-1)).questionId), {
        outcome: "cancelled"
      })
    )
    await expect(question).resolves.toMatchObject({ behavior: "deny" })

    await run(created.handle.setMode("acceptEdits"))
    expect(fake.permissionModes).toEqual(["acceptEdits"])
    expect(events.at(-1)?.payload).toMatchObject({ modeId: "acceptEdits" })
    const asked = fake.options!.canUseTool!("Bash", { command: "ls" }, toolCheck())
    await fake.drain()
    expect(payloadOf(events.at(-1)).questions).toMatchObject([{ header: "Permission" }])
    await run(
      created.handle.answerQuestion!(stringValue(payloadOf(events.at(-1)).questionId), {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(asked).resolves.toMatchObject({ behavior: "deny" })
  })

  it("surfaces ExitPlanMode as a plan-approval question: implement allows, keep planning denies", async () => {
    const { fake, events, created } = await startTestSession()

    const planFilePath = "/home/user/.claude/plans/golden-gathering-eagle.md"
    const toolInput = { plan: "# The Plan\n\n1. Do it", planFilePath }
    const decision = fake.options!.canUseTool!("ExitPlanMode", toolInput, toolCheck())
    await fake.drain()
    expect(events.at(-2)?.payload).toEqual({
      markdown: "# The Plan\n\n1. Do it",
      sessionUpdate: "plan_document"
    })
    const asked = payloadOf(events.at(-1))
    expect(asked).toMatchObject({ sessionUpdate: "question" })
    expect(asked.message).toBeUndefined()
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Plan",
        id: "exit_plan_mode",
        options: [
          { description: "Start building", label: "Implement plan" },
          { description: "Keep refining in plan mode", label: "Keep planning" }
        ],
        question: "Ready to implement this plan?"
      }
    ])
    await run(
      created.handle.answerQuestion!(stringValue(asked.questionId), {
        answers: { exit_plan_mode: { answers: ["Implement plan"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    const kept = fake.options!.canUseTool!("ExitPlanMode", toolInput, toolCheck())
    await fake.drain()
    const keptAsk = payloadOf(events.at(-1))
    await run(
      created.handle.answerQuestion!(stringValue(keptAsk.questionId), {
        answers: { exit_plan_mode: { answers: ["Keep planning"] } },
        outcome: "answered"
      })
    )
    await expect(kept).resolves.toEqual({
      behavior: "deny",
      message: "The user wants to keep refining the plan. Stay in plan mode and continue planning."
    })

    const refinedInput = { plan: "# The Plan\n\n1. Do it\n2. Check it", planFilePath }
    const refined = fake.options!.canUseTool!("ExitPlanMode", refinedInput, toolCheck())
    await fake.drain()
    expect(events.at(-2)?.payload).toEqual({
      markdown: "# The Plan\n\n1. Do it\n2. Check it",
      sessionUpdate: "plan_document"
    })
    const refinedAsk = payloadOf(events.at(-1))
    await run(
      created.handle.answerQuestion!(stringValue(refinedAsk.questionId), {
        answers: { exit_plan_mode: { answers: ["Keep planning"], note: " Split step 2 " } },
        outcome: "answered"
      })
    )
    await expect(refined).resolves.toEqual({
      behavior: "deny",
      message:
        "The user wants to keep refining the plan. Stay in plan mode and continue planning.\n\n" +
        "The user's feedback on the plan:\nSplit step 2"
    })

    const before = events.length
    void fake.options!.canUseTool!("ExitPlanMode", {}, toolCheck())
    await fake.drain()
    expect(events.slice(before).map((event) => payloadOf(event).sessionUpdate)).toEqual([
      "question"
    ])
  })

  it("blocks AskUserQuestion on the human's answer and folds it into updatedInput", async () => {
    const { fake, events, created } = await startTestSession()

    const toolInput = {
      questions: [
        {
          header: "Auth",
          multiSelect: false,
          options: [
            { description: "Fast to ship.", label: "JWT (Recommended)" },
            { description: "Simpler infra.", label: "Sessions" }
          ],
          question: "Which auth method?"
        },
        {
          multiSelect: true,
          options: [{ label: "Web" }, { label: "iOS" }],
          question: "Which platforms?"
        }
      ]
    }
    const decision = fake.options!.canUseTool!("AskUserQuestion", toolInput, toolCheck())
    await fake.drain()
    const asked = payloadOf(events.at(-1))
    expect(asked.sessionUpdate).toBe("question")
    const questionId = stringValue(asked.questionId)
    expect(asked.questions).toMatchObject([
      { allowsOther: true, header: "Auth", id: "question_0" },
      { allowsOther: true, id: "question_1", multiSelect: true }
    ])

    await run(
      created.handle.answerQuestion!(questionId, {
        answers: {
          question_0: { answers: [], note: "Use magic links" },
          question_1: { answers: ["Web", "iOS"], note: "mobile can come later" }
        },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({
      behavior: "allow",
      updatedInput: {
        ...toolInput,
        answers: {
          "Which auth method?": "Use magic links",
          "Which platforms?": "Web, iOS — mobile can come later"
        }
      }
    })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "answered",
      questionId,
      sessionUpdate: "question_resolved"
    })
    expect(
      events.filter((event) => {
        const payload = payloadOf(event)
        return payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      })
    ).toEqual([])
  })

  it("leaves skipped and blank answers out of updatedInput", async () => {
    const { fake, events, created } = await startTestSession()

    const toolInput = {
      questions: [
        { options: [{ label: "Web" }, { label: "iOS" }], question: "Which platforms?" },
        { options: [{ label: "Yes" }], question: "Ship today?" },
        { options: [], question: "Anything else?" }
      ]
    }
    const decision = fake.options!.canUseTool!("AskUserQuestion", toolInput, toolCheck())
    await fake.drain()
    const questionId = stringValue(payloadOf(events.at(-1)).questionId)

    await run(
      created.handle.answerQuestion!(questionId, {
        answers: {
          question_0: { answers: ["Web"] },
          question_2: { answers: [], note: "  " }
        },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({
      behavior: "allow",
      updatedInput: { ...toolInput, answers: { "Which platforms?": "Web" } }
    })
  })

  it("cancelling a question denies the tool; interrupts deny all held questions", async () => {
    const { fake, events, created } = await startTestSession()

    const ask = (question: string) =>
      fake.options!.canUseTool!(
        "AskUserQuestion",
        { questions: [{ options: [{ label: "A" }], question }] },
        toolCheck()
      )

    const first = ask("First?")
    await fake.drain()
    const firstId = stringValue(payloadOf(events.at(-1)).questionId)
    await run(created.handle.answerQuestion!(firstId, { outcome: "cancelled" }))
    await expect(first).resolves.toEqual({
      behavior: "deny",
      message: "User dismissed the question without answering."
    })

    await expect(
      run(created.handle.answerQuestion!("nope", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
    await expect(
      fake.options!.canUseTool!("AskUserQuestion", { questions: "?" }, toolCheck())
    ).resolves.toMatchObject({ behavior: "allow" })

    const second = ask("Second?")
    await fake.drain()
    await run(created.handle.cancel)
    await expect(second).resolves.toMatchObject({ behavior: "deny" })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      sessionUpdate: "question_resolved"
    })
  })
  it("replying to a question denies the tool with the user's reply", async () => {
    const { fake, events, created } = await startTestSession()
    const reply = { text: " Use magic links " }
    const replied = "The user replied instead: Use magic links"

    const question = fake.options!.canUseTool!(
      "AskUserQuestion",
      { questions: [{ options: [{ label: "A" }], question: "Which?" }] },
      toolCheck()
    )
    await fake.drain()
    const questionId = stringValue(payloadOf(events.at(-1)).questionId)
    await expect(run(created.handle.replyToQuestion!(questionId, reply))).resolves.toBe(true)
    await expect(question).resolves.toEqual({ behavior: "deny", message: replied })
    expect(events.at(-1)?.payload).toEqual({
      outcome: "replied",
      questionId,
      questions: expect.any(Array),
      sessionUpdate: "question_resolved"
    })

    await run(created.handle.setMode("default"))
    const approval = fake.options!.canUseTool!("Bash", { command: "ls" }, toolCheck())
    await fake.drain()
    const approvalId = stringValue(payloadOf(events.at(-1)).questionId)
    await expect(run(created.handle.replyToQuestion!(approvalId, reply))).resolves.toBe(true)
    await expect(approval).resolves.toEqual({ behavior: "deny", message: replied })

    const plan = fake.options!.canUseTool!("ExitPlanMode", {}, toolCheck())
    await fake.drain()
    const planId = stringValue(payloadOf(events.at(-1)).questionId)
    await expect(run(created.handle.replyToQuestion!(planId, reply))).resolves.toBe(true)
    await expect(plan).resolves.toEqual({
      behavior: "deny",
      message:
        "The user wants to keep refining the plan. Stay in plan mode and continue planning.\n\n" +
        `The user's feedback on the plan:\n${replied}`
    })

    await expect(run(created.handle.replyToQuestion!("nope", reply))).rejects.toThrow(
      "No pending question"
    )
  })

  it("a reply that can't travel as text declines the question neutrally", async () => {
    const { fake, events, created } = await startTestSession()
    const neutral = { behavior: "deny", message: "The user replied instead of answering." }

    const question = fake.options!.canUseTool!(
      "AskUserQuestion",
      { questions: [{ options: [{ label: "A" }], question: "Which?" }] },
      toolCheck()
    )
    await fake.drain()
    const questionId = stringValue(payloadOf(events.at(-1)).questionId)
    await expect(run(created.handle.replyToQuestion!(questionId, { text: "  " }))).resolves.toBe(
      false
    )
    await expect(question).resolves.toEqual(neutral)

    const plan = fake.options!.canUseTool!("ExitPlanMode", {}, toolCheck())
    await fake.drain()
    const planId = stringValue(payloadOf(events.at(-1)).questionId)
    await expect(run(created.handle.replyToQuestion!(planId, { text: "" }))).resolves.toBe(false)
    await expect(plan).resolves.toEqual(neutral)
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "replied",
      sessionUpdate: "question_resolved"
    })
  })
})
