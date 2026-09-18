import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

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
    await run(created.handle.setMode!("default"))
    expect(fake.permissionModes).toEqual(["default"])

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

    // Full access is acknowledged to the SDK explicitly, as it requires.
    expect(fake.options?.allowDangerouslySkipPermissions).toBe(true)
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")

    // The CLI's Bash safety checks (e.g. variable loops in a subagent) still
    // reach canUseTool under bypass; full access answers them without a prompt.
    const toolInput = { command: 'for f in a b; do grep -n "$f" .; done' }
    const eventsBefore = events.length
    await expect(
      fake.options!.canUseTool!(
        "Bash",
        toolInput as never,
        {
          agentID: "a120e6ad",
          decisionReason: "variable loop cannot be statically validated"
        } as never
      )
    ).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })
    expect(events.length).toBe(eventsBefore)
    expect(log).toHaveBeenCalledWith(expect.stringContaining("agent=a120e6ad"))
    expect(log).toHaveBeenCalledWith(expect.stringContaining("variable loop"))

    // Questions and plan approvals are still the human's to answer.
    const question = fake.options!.canUseTool!(
      "AskUserQuestion",
      { questions: [{ header: "Scope", question: "Which?", options: [{ label: "A" }] }] } as never,
      {} as never
    )
    await fake.drain()
    expect((events.at(-1)?.payload as Record<string, unknown>).sessionUpdate).toBe("question")
    await run(
      created.handle.answerQuestion!(
        (events.at(-1)?.payload as Record<string, unknown>).questionId as string,
        { outcome: "cancelled" }
      )
    )
    await expect(question).resolves.toMatchObject({ behavior: "deny" })

    // Leaving full access restores the prompt.
    await run(created.handle.setMode!("acceptEdits"))
    expect(fake.permissionModes).toEqual(["acceptEdits"])
    expect(events.at(-1)?.payload).toMatchObject({ modeId: "acceptEdits" })
    const asked = fake.options!.canUseTool!("Bash", { command: "ls" } as never, {} as never)
    await fake.drain()
    expect((events.at(-1)?.payload as Record<string, unknown>).questions).toMatchObject([
      { header: "Permission" }
    ])
    await run(
      created.handle.answerQuestion!(
        (events.at(-1)?.payload as Record<string, unknown>).questionId as string,
        { answers: { approval: { answers: ["Deny"] } }, outcome: "answered" }
      )
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
