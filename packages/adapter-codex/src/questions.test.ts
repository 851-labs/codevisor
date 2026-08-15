import { afterEach, describe, expect, it, vi } from "vitest"
import { run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("rejects unknown server requests", async () => {
    const { client } = await setup()
    await expect(client.serverRequest("something/else", {})).rejects.toThrow(
      "Unsupported approval request"
    )
  })

  it("holds requestUserInput open until answered, mapping notes onto the reply", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q1",
      questions: [
        {
          header: "Approach",
          id: "approach",
          isOther: true,
          isSecret: false,
          options: [
            { description: "Fastest to ship.", label: "MVP first (Recommended)" },
            { description: "Safer long-term.", label: "Full design" }
          ],
          question: "Which approach should I take?"
        }
      ],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({
      questionId: "item-q1",
      sessionUpdate: "question"
    })
    expect(asked.questions).toEqual([
      {
        allowsOther: true,
        header: "Approach",
        id: "approach",
        options: [
          { description: "Fastest to ship.", label: "MVP first (Recommended)" },
          { description: "Safer long-term.", label: "Full design" }
        ],
        question: "Which approach should I take?"
      }
    ])

    await run(
      created!.handle.answerQuestion!("item-q1", {
        answers: { approach: { answers: ["MVP first (Recommended)"], note: "keep it small" } },
        outcome: "answered"
      })
    )
    await expect(request).resolves.toEqual({
      answers: { approach: { answers: ["MVP first (Recommended)", "user_note: keep it small"] } }
    })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "answered",
      questionId: "item-q1",
      sessionUpdate: "question_resolved",
      answers: { approach: { answers: ["MVP first (Recommended)"], note: "keep it small" } }
    })

    // Answering again fails: the question is no longer pending.
    await expect(
      run(created!.handle.answerQuestion!("item-q1", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
  })

  it("cancel rejects the held question so the model sees it was dismissed", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q2",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    await run(created!.handle.answerQuestion!("item-q2", { outcome: "cancelled" }))
    await expect(request).rejects.toThrow("dismissed")
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      questionId: "item-q2",
      sessionUpdate: "question_resolved"
    })
  })

  it("retracts a held question when the codex connection dies (abort signal)", async () => {
    const { client, created, events } = await setup()
    const controller = new AbortController()
    const request = client.serverRequest(
      "item/tool/requestUserInput",
      {
        itemId: "item-q-dead",
        questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
        threadId: "thread-new",
        turnId: "turn-1"
      },
      controller.signal
    )
    await Promise.resolve()
    // The process died with the question still on screen: the ask is
    // retracted so the picker dismisses instead of collecting an answer
    // no one will ever receive.
    controller.abort(new Error("codex app-server exited"))
    await expect(request).rejects.toThrow("codex connection closed")
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      questionId: "item-q-dead",
      sessionUpdate: "question_resolved"
    })
    // The retraction already emptied the pending map: answering afterwards
    // fails, and close-time cancellation finds nothing left to do.
    await expect(
      run(created!.handle.answerQuestion!("item-q-dead", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
  })

  it("auto-resolves timed questions with empty answers, codex-TUI style", async () => {
    vi.useFakeTimers()
    const { client, events } = await setup()
    const request = client.serverRequest("item/tool/requestUserInput", {
      autoResolutionMs: 60_000,
      itemId: "item-q3",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    vi.advanceTimersByTime(60_000)
    await expect(request).resolves.toEqual({ answers: {} })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "autoResolved",
      questionId: "item-q3",
      sessionUpdate: "question_resolved"
    })
    vi.useRealTimers()
  })

  it("turn interrupt and turn completion cancel any held questions", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("go"))
    await Promise.resolve()
    client.emit("turn/started", { threadId: "thread-new", turn: { id: "turn-q" } })
    const request = client.serverRequest("item/tool/requestUserInput", {
      itemId: "item-q4",
      questions: [{ id: "q", isOther: true, options: [{ label: "A" }], question: "Pick" }],
      threadId: "thread-new",
      turnId: "turn-q"
    })
    await Promise.resolve()
    await run(created!.handle.cancel)
    await expect(request).rejects.toThrow("cancelled with the turn")
    expect(
      events.some((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.sessionUpdate === "question_resolved" && payload.outcome === "cancelled"
      })
    ).toBe(true)
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-q", status: "interrupted" }
    })
    await promptPromise
  })

  it("maps MCP elicitation forms onto questions and coerces typed answers back", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("mcpServer/elicitation/request", {
      message: "GitHub needs a few details.",
      mode: "form",
      requestedSchema: {
        properties: {
          confirm: { title: "Proceed with login?", type: "boolean" },
          environment: {
            description: "Which environment?",
            oneOf: [
              { const: "prod", title: "Production" },
              { const: "stg", title: "Staging" }
            ],
            type: "string"
          },
          retries: { title: "Retry count", type: "integer" },
          token: { description: "Personal access token", type: "string" }
        },
        required: ["token"],
        type: "object"
      },
      serverName: "github",
      threadId: "thread-new",
      turnId: null
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.sessionUpdate).toBe("question")
    expect(asked.message).toBe("GitHub needs a few details.")
    const questionId = asked.questionId as string
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        id: "confirm",
        options: [{ label: "Yes" }, { label: "No" }],
        question: "Proceed with login?"
      },
      {
        allowsOther: false,
        id: "environment",
        options: [{ label: "Production" }, { label: "Staging" }],
        question: "Which environment?"
      },
      { allowsOther: true, id: "retries", options: [], question: "Retry count" },
      { allowsOther: true, id: "token", options: [], question: "Personal access token" }
    ])

    await run(
      created!.handle.answerQuestion!(questionId, {
        answers: {
          confirm: { answers: ["Yes"] },
          environment: { answers: ["Staging"] },
          retries: { answers: [], note: "3" },
          token: { answers: [], note: "ghp_secret" }
        },
        outcome: "answered"
      })
    )
    // Enum labels map back to const values; booleans and numbers coerce.
    await expect(request).resolves.toEqual({
      action: "accept",
      content: { confirm: true, environment: "stg", retries: 3, token: "ghp_secret" }
    })
  })

  it("cancels MCP elicitations with the MCP action and declines url mode", async () => {
    const { client, created, events } = await setup()
    const request = client.serverRequest("mcpServer/elicitation/request", {
      message: "Pick one.",
      mode: "form",
      requestedSchema: {
        properties: { choice: { enum: ["a", "b"], enumNames: ["Alpha", "Beta"], type: "string" } },
        type: "object"
      },
      serverName: "svc",
      threadId: "thread-new",
      turnId: null
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        id: "choice",
        options: [{ label: "Alpha" }, { label: "Beta" }],
        question: "choice"
      }
    ])
    // Dismissing resolves with the MCP cancel action (never a JSON-RPC error).
    await run(created!.handle.answerQuestion!(asked.questionId as string, { outcome: "cancelled" }))
    await expect(request).resolves.toEqual({ action: "cancel", content: null })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      sessionUpdate: "question_resolved"
    })

    await expect(
      client.serverRequest("mcpServer/elicitation/request", {
        message: "Open this URL",
        mode: "url",
        serverName: "svc",
        threadId: "thread-new",
        turnId: null,
        url: "https://example.com/auth"
      })
    ).resolves.toEqual({ action: "decline", content: null })
  })

  it("surfaces approvals as Allow/Deny questions with item context", async () => {
    const { client, created, events } = await setup()
    // The item opens first; its command becomes the approval prompt's detail.
    client.emit("item/started", {
      item: {
        command: "rm -rf build",
        id: "cmd-1",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const approval = client.serverRequest("item/commandExecution/requestApproval", {
      itemId: "cmd-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({
      message: "rm -rf build",
      sessionUpdate: "question"
    })
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Command",
        id: "approval",
        options: [{ label: "Allow" }, { label: "Allow for session" }, { label: "Deny" }],
        question: "Allow this command to run?"
      }
    ])
    await run(
      created!.handle.answerQuestion!(asked.questionId as string, {
        answers: { approval: { answers: ["Allow for session"] } },
        outcome: "answered"
      })
    )
    await expect(approval).resolves.toEqual({ decision: "acceptForSession" })

    // Deny and dismissal map onto decline/cancel.
    const denied = client.serverRequest("item/fileChange/requestApproval", {
      itemId: "edit-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const deniedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created!.handle.answerQuestion!(deniedAsk.questionId as string, {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(denied).resolves.toEqual({ decision: "decline" })

    const dismissed = client.serverRequest("item/permissions/requestApproval", {
      itemId: "perm-1",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()
    const dismissedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created!.handle.answerQuestion!(dismissedAsk.questionId as string, { outcome: "cancelled" })
    )
    await expect(dismissed).resolves.toEqual({ decision: "cancel" })
  })

  it("rejects requestUserInput asks that carry no questions", async () => {
    const { client } = await setup()
    await expect(
      client.serverRequest("item/tool/requestUserInput", {
        itemId: "item-q5",
        questions: [],
        threadId: "thread-new",
        turnId: "turn-1"
      })
    ).rejects.toThrow("no questions")
  })
})
