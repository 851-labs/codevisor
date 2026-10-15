import { describe, expect, it } from "vitest"

import { messageOf } from "./protocol.js"
import {
  approvalRequest,
  modelCatalog,
  museItem,
  museSessions,
  requireSession,
  userInputRequest
} from "./wire.js"

describe("Muse wire parsing", () => {
  it("reads an item's known fields and drops the ones of the wrong type", () => {
    expect(
      museItem({
        itemId: "i1",
        kind: "toolCall",
        status: "completed",
        revision: 3,
        turnId: "t1",
        text: "done",
        summary: ["a", 2],
        tool: "edit_file",
        args: "{}",
        visibleOutput: "ok",
        patchSummary: { files: 2, added: 3, removed: 1 },
        failureReason: "nope",
        childSessionId: "c1",
        controlStatus: "running",
        objective: "fix",
        role: "reviewer",
        agentPath: "/root/fix",
        subagentId: "sa",
        result: { summary: "s", text: "t" },
        selector: "plan",
        query: "q",
        url: "https://example.com"
      })
    ).toEqual({
      itemId: "i1",
      kind: "toolCall",
      status: "completed",
      revision: 3,
      turnId: "t1",
      text: "done",
      summary: ["a"],
      tool: "edit_file",
      args: "{}",
      visibleOutput: "ok",
      patchSummary: { files: 2, added: 3, removed: 1 },
      failureReason: "nope",
      childSessionId: "c1",
      controlStatus: "running",
      objective: "fix",
      role: "reviewer",
      agentPath: "/root/fix",
      subagentId: "sa",
      result: { summary: "s", text: "t" },
      selector: "plan",
      query: "q",
      url: "https://example.com"
    })
    expect(
      museItem({ itemId: "i2", turnId: null, text: 4, patchSummary: { added: 1, removed: 0 } })
    ).toEqual({
      itemId: "i2",
      kind: "",
      status: "",
      revision: 0,
      turnId: null,
      summary: [],
      patchSummary: { files: 0, added: 1, removed: 0 },
      result: {}
    })
    expect(museItem({ itemId: "i3", patchSummary: { added: 1 } })?.patchSummary).toBeUndefined()
    expect(museItem({ kind: "toolCall" })).toBeUndefined()
  })

  it("requires a session id and fills the fields Muse left out", () => {
    expect(museSessions([{ sessionId: "s1" }, { title: "orphan" }, "junk"])).toEqual([
      { sessionId: "s1", workspaceRoot: null, modelId: null, providerId: null, updatedAt: "" }
    ])
    expect(() => requireSession({})).toThrow("Muse Code didn't return a session.")
  })

  it("keeps the models that have an id", () => {
    expect(
      modelCatalog([
        { modelId: "m", reasoningEffortVariants: [{ tier: "low" }, { level: "high" }] },
        { displayLabel: "nameless" }
      ])
    ).toEqual([
      {
        modelId: "m",
        displayLabel: "m",
        providerId: "",
        profileId: null,
        contextLimit: null,
        isActive: false,
        isDefault: false,
        variants: [],
        reasoningEffortVariants: [{ tier: "low" }]
      }
    ])
    expect(
      modelCatalog([
        { modelId: "m", displayLabel: "M", providerId: "p", profileId: "f", contextLimit: 9 }
      ])[0]
    ).toMatchObject({ displayLabel: "M", providerId: "p", profileId: "f", contextLimit: 9 })
  })

  it("reads approval requests, skipping choices without an id", () => {
    expect(
      approvalRequest({
        approvalId: "ap",
        availableChoices: [{ choiceId: "c" }, { label: "no id" }],
        currentRequirementId: { approvalId: "ap", sourceIndex: 1, extra: true }
      })
    ).toEqual({
      approvalId: "ap",
      sessionId: "",
      toolName: "tool",
      toolCallId: "",
      rawArgs: "",
      availableChoices: [{ choiceId: "c", label: "c", decision: "" }],
      currentRequirementId: { approvalId: "ap", sourceIndex: 1, extra: true },
      subject: { kind: "" }
    })
    expect(
      approvalRequest({
        approvalId: "ap",
        sessionId: "s",
        toolName: "bash",
        toolCallId: "call",
        rawArgs: "{}",
        availableChoices: [{ choiceId: "c", label: "Allow", decision: "approved" }],
        subject: { kind: "shell", command: "ls", path: "/" }
      })
    ).toMatchObject({
      sessionId: "s",
      toolName: "bash",
      toolCallId: "call",
      rawArgs: "{}",
      availableChoices: [{ choiceId: "c", label: "Allow", decision: "approved" }],
      currentRequirementId: {},
      subject: { kind: "shell", command: "ls", path: "/" }
    })
    expect(approvalRequest({ sessionId: "s" })).toBeUndefined()
  })

  it("reads user-input requests, skipping questions and options it can't show", () => {
    expect(
      userInputRequest({
        userInputId: "ui",
        questions: [
          { id: "q", options: [{ label: "A" }, { description: "unlabelled" }] },
          { header: "no id" }
        ]
      })
    ).toEqual({
      userInputId: "ui",
      sessionId: "",
      questions: [
        {
          id: "q",
          header: "",
          question: "",
          options: [{ label: "A" }],
          selection: { mode: "single" }
        }
      ]
    })
    expect(userInputRequest({ questions: [] })).toBeUndefined()
  })

  it("describes thrown values that aren't errors", () => {
    expect(messageOf(new Error("boom"))).toBe("boom")
    expect(messageOf("plain")).toBe("plain")
  })
})
