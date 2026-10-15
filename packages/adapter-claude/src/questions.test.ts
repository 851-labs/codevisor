import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  run,
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
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise
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
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise
    const log = vi.spyOn(console, "error").mockImplementation(() => {})

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
    log.mockRestore()
  })

  it("surfaces ExitPlanMode as a plan-approval question: implement allows, keep planning denies", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

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
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

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

  it("cancelling a question denies the tool; interrupts deny all held questions", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

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
})
