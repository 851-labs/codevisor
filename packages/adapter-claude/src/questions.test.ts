import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { definition, FakeQuery, initMessage, makeProvider, run } from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
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

    const toolInput = { command: "rm -rf build" }
    const decision = fake.options!.canUseTool!("Bash", toolInput as never, {} as never)
    await fake.drain()
    const asked = events.at(-1)?.payload as Record<string, unknown>
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
      created.handle.answerQuestion!(asked.questionId as string, {
        answers: { approval: { answers: ["Allow"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    // Deny (and dismissal) reject the tool.
    const denied = fake.options!.canUseTool!("Edit", { file_path: "/tmp/a" } as never, {} as never)
    await fake.drain()
    const deniedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created.handle.answerQuestion!(deniedAsk.questionId as string, {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(denied).resolves.toEqual({
      behavior: "deny",
      message: "User denied permission."
    })
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

    const toolInput = { plan: "# The Plan\n\n1. Do it" }
    const decision = fake.options!.canUseTool!("ExitPlanMode", toolInput as never, {} as never)
    await fake.drain()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({ sessionUpdate: "question" })
    // No "message" line — the plan itself rides a separate plan_document.
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
      created.handle.answerQuestion!(asked.questionId as string, {
        answers: { exit_plan_mode: { answers: ["Implement plan"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    // Keeping planning denies the tool with a message that nudges more planning.
    const kept = fake.options!.canUseTool!("ExitPlanMode", toolInput as never, {} as never)
    await fake.drain()
    const keptAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created.handle.answerQuestion!(keptAsk.questionId as string, {
        answers: { exit_plan_mode: { answers: ["Keep planning"] } },
        outcome: "answered"
      })
    )
    await expect(kept).resolves.toEqual({
      behavior: "deny",
      message: "The user wants to keep refining the plan. Stay in plan mode and continue planning."
    })
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
    const decision = fake.options!.canUseTool!("AskUserQuestion", toolInput as never, {} as never)
    await fake.drain()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.sessionUpdate).toBe("question")
    const questionId = asked.questionId as string
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
    // A bare note is the answer (the "Other" path); a note alongside labels
    // supplements them; keys are the question text (the SDK tool reads them
    // back that way).
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
    // No tool_call lifecycle leaked for the question tool.
    expect(
      events.filter((event) => {
        const payload = event.payload as Record<string, unknown>
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
        { questions: [{ options: [{ label: "A" }], question }] } as never,
        {} as never
      )

    const first = ask("First?")
    await fake.drain()
    const firstId = (events.at(-1)?.payload as Record<string, unknown>).questionId as string
    await run(created.handle.answerQuestion!(firstId, { outcome: "cancelled" }))
    await expect(first).resolves.toEqual({
      behavior: "deny",
      message: "User dismissed the question without answering."
    })

    // Unknown ids fail; malformed inputs pass straight through as allow.
    await expect(
      run(created.handle.answerQuestion!("nope", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
    await expect(
      fake.options!.canUseTool!("AskUserQuestion", { questions: "?" } as never, {} as never)
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
