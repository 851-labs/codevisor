import { describe, expect, it } from "vitest"

import { configOptions, defaultTier, modelTiers } from "./models.js"
import { approvalQuestion, userInputQuestion } from "./questions.js"
import { lite, spark } from "./test-support.js"
import {
  contextUsageUpdate,
  museSkills,
  planUpdate,
  tokenUsageUpdate,
  turnInput
} from "./updates.js"

const skills = museSkills({
  skills: [
    { selector: "plan", displayName: "plan", description: " Plan first. ", source: "bundled" },
    { selector: "review", displayName: "Review", source: "project" },
    { selector: "mine", source: "user", description: "" },
    { selector: "computer-use", displayName: "computer-use", source: "user" },
    { displayName: "no selector" }
  ]
})

describe("session updates", () => {
  it("lists Muse's skills as /selector, leaving out ones Codevisor replaces", () => {
    expect(skills).toEqual({
      invocationPrefix: "/",
      skills: [
        { invocation: "/plan", name: "plan", description: "Plan first." },
        { invocation: "/review", name: "Review", source: "project" },
        { invocation: "/mine", name: "mine", source: "user" }
      ]
    })
    expect(museSkills({})).toEqual({ invocationPrefix: "/", skills: [] })
  })

  it("sends a leading /skill as a skill part, everything else as text and images", () => {
    expect(turnInput({ text: "/plan add caching " }, skills.skills)).toEqual([
      { type: "skill", selector: "plan", arguments: "add caching" }
    ])
    expect(turnInput({ text: "/review" }, skills.skills)).toEqual([
      { type: "skill", selector: "review" }
    ])
    expect(turnInput({ text: "/tmp is full" }, skills.skills)).toEqual([
      { type: "text", text: "/tmp is full" }
    ])
    const image = {
      name: "a.png",
      mimeType: "image/png",
      kind: "image" as const,
      sizeBytes: 3,
      path: "/up/a.png",
      inline: { mimeType: "image/png", data: Buffer.from("png") }
    }
    const file = {
      name: "b.pdf",
      mimeType: "application/pdf",
      kind: "file" as const,
      sizeBytes: 9,
      path: "/up/b.pdf"
    }
    const parts = turnInput({ text: "look", attachments: [image, file] }, [])
    expect(parts[0]).toMatchObject({ type: "text", text: expect.stringContaining("/up/b.pdf") })
    expect(parts[1]).toEqual({
      type: "image",
      base64Data: Buffer.from("png").toString("base64"),
      mediaType: "image/png"
    })
    expect(turnInput({ text: "", attachments: [image] }, [])).toEqual([parts[1]])
    expect(turnInput({ text: "/plan", attachments: [image] }, skills.skills)).toEqual([
      { type: "skill", selector: "plan" },
      parts[1]
    ])
  })

  it("reports running token totals and context occupancy", () => {
    expect(
      tokenUsageUpdate({
        usage: {
          inputTokens: 27442,
          outputTokens: 354,
          cachedTokens: 0,
          cacheReadTokens: 12,
          reasoningTokens: 272
        },
        promptTokens: 27442,
        totalTokens: 27796,
        cumulative: { promptTokens: 55000, outputTokens: 700, totalTokens: 55700 }
      })
    ).toEqual({
      sessionUpdate: "usage_update",
      used: 27796,
      inputTokens: 55000,
      outputTokens: 700,
      totalTokens: 55700,
      cachedInputTokens: 12,
      reasoningOutputTokens: 272
    })
    expect(tokenUsageUpdate({ usage: { cachedTokens: 5 } })).toEqual({
      sessionUpdate: "usage_update",
      cachedInputTokens: 5
    })
    expect(contextUsageUpdate({ usedTokens: 900, windowTokens: 200000, pressure: "low" })).toEqual({
      sessionUpdate: "usage_update",
      used: 900,
      size: 200000
    })
    expect(contextUsageUpdate({ usedTokens: Number.NaN })).toEqual({
      sessionUpdate: "usage_update"
    })
  })

  it("replaces the checklist with Muse's todos, dropping cancelled ones", () => {
    expect(
      planUpdate({
        items: [
          { text: "Read code", status: "completed" },
          { text: "Fix bug", status: "inProgress" },
          { text: "Ship", status: "pending" },
          { text: "Abandoned", status: "cancelled" },
          { status: "pending" }
        ]
      })
    ).toEqual({
      sessionUpdate: "plan",
      entries: [
        { content: "Read code", priority: "medium", status: "completed" },
        { content: "Fix bug", priority: "medium", status: "in_progress" },
        { content: "Ship", priority: "medium", status: "pending" }
      ]
    })
    expect(planUpdate({})).toEqual({ sessionUpdate: "plan", entries: [] })
  })
})

describe("models", () => {
  it("offers the catalog and the current model's reasoning tiers", () => {
    expect(configOptions({ models: [spark, lite], modelId: "lite", effort: undefined })).toEqual([
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "lite",
        options: [
          { value: "spark", name: "Muse Spark" },
          { value: "lite", name: "Muse Lite" }
        ]
      },
      {
        id: "thought_level",
        name: "Reasoning",
        category: "thought_level",
        currentValue: "minimal",
        options: [
          { value: "minimal", name: "Minimal" },
          { value: "low", name: "Low" }
        ]
      }
    ])
    expect(
      configOptions({ models: [lite, spark], modelId: "gone", effort: "high" })[1]
    ).toMatchObject({
      currentValue: "high"
    })
    expect(configOptions({ models: [], modelId: undefined, effort: undefined })).toEqual([])
  })

  it("falls back to the default, then the first model; and to the described tiers", () => {
    const plain = { ...lite, variants: [] as Array<string>, isActive: false }
    const described = {
      ...spark,
      isActive: false,
      isDefault: true,
      variants: {},
      reasoningEffortVariants: [{ tier: "low" }, { tier: "max" }],
      defaultReasoningEffort: "max"
    }
    expect(
      configOptions({ models: [plain, described], modelId: undefined, effort: "ultra" })
    ).toEqual([
      expect.objectContaining({ currentValue: "spark" }),
      expect.objectContaining({
        currentValue: "max",
        options: [
          { value: "low", name: "Low" },
          { value: "max", name: "Max" }
        ]
      })
    ])
    expect(configOptions({ models: [plain], modelId: undefined, effort: undefined })).toEqual([
      expect.objectContaining({ currentValue: "lite" })
    ])
    expect(modelTiers({ ...plain, variants: ["low", 3 as unknown as string] })).toEqual(["low"])
    expect(modelTiers(undefined)).toEqual([])
    expect(defaultTier({ ...spark, defaultReasoningEffort: "ultra" })).toBe("medium")
    expect(defaultTier({ ...lite, variants: ["xhigh", "low"] })).toBe("xhigh")
    expect(
      configOptions({
        models: [{ ...lite, variants: ["turbo"] }],
        modelId: undefined,
        effort: undefined
      })[1]
    ).toMatchObject({
      options: [{ value: "turbo", name: "turbo" }]
    })
  })
})

describe("questions", () => {
  const approval = {
    approvalId: "ap-1",
    sessionId: "s-1",
    toolName: "bash",
    toolCallId: "call_1",
    rawArgs: "{}",
    subject: { kind: "shell", command: "rm -rf build" },
    currentRequirementId: { approvalId: "ap-1", sourceIndex: 0 },
    availableChoices: [
      { choiceId: "allow_once", label: "Allow once", decision: "approved" },
      { choiceId: "allow_session", label: "Allow for session", decision: "approvedForSession" },
      { choiceId: "deny", label: "Deny", decision: "denied" }
    ]
  }

  it("asks with Muse's own choices and decides with the one picked", () => {
    const question = approvalQuestion(approval)
    expect(question.specs).toEqual([
      {
        id: "permission",
        header: "Permission",
        question: "Allow bash: rm -rf build?",
        options: [{ label: "Allow once" }, { label: "Allow for session" }, { label: "Deny" }],
        allowsOther: false
      }
    ])
    expect(
      question.reply({
        outcome: "answered",
        answers: { permission: { answers: ["Allow for session"] } }
      })
    ).toEqual({
      method: "approval/decide",
      params: {
        commandId: expect.any(String),
        sessionId: "s-1",
        approvalId: "ap-1",
        requirementId: { approvalId: "ap-1", sourceIndex: 0 },
        choiceId: "allow_session"
      }
    })
    expect(question.reply({ outcome: "cancelled" }).params.choiceId).toBe("deny")
    const withAbort = approvalQuestion({
      ...approval,
      subject: { kind: "fileAccess", path: "/etc/hosts" },
      availableChoices: [
        ...approval.availableChoices,
        { choiceId: "stop", label: "Stop", decision: "abort" }
      ]
    })
    expect(withAbort.specs[0]!.question).toBe("Allow bash: /etc/hosts?")
    expect(withAbort.reply({ outcome: "answered", answers: {} }).params.choiceId).toBe("stop")
    const noRefusal = approvalQuestion({
      ...approval,
      subject: { kind: "tool" },
      availableChoices: approval.availableChoices.slice(0, 2)
    })
    expect(noRefusal.specs[0]!.question).toBe("Allow bash?")
    expect(noRefusal.reply({ outcome: "cancelled" })).toEqual({
      method: "turn/interrupt",
      params: { commandId: expect.any(String), sessionId: "s-1" }
    })
    const rejecting = approvalQuestion({
      ...approval,
      availableChoices: [
        approval.availableChoices[0]!,
        { choiceId: "reject", label: "Reject", decision: "rejected" }
      ]
    })
    expect(rejecting.reply({ outcome: "cancelled" }).params.choiceId).toBe("reject")
  })

  it("answers Muse's questions with labels, multi-selections or free text", () => {
    const request = {
      userInputId: "ui-1",
      sessionId: "s-1",
      autoResolutionMs: 60000,
      questions: [
        {
          id: "db",
          header: "Database",
          question: "Which DB?",
          options: [{ label: "Postgres", description: "SQL" }, { label: "Redis" }],
          selection: { mode: "single" }
        },
        {
          id: "envs",
          header: "",
          question: "Where?",
          options: [{ label: "dev" }, { label: "prod" }],
          selection: { mode: "multiple" }
        }
      ]
    }
    const question = userInputQuestion(request)
    expect(question.autoResolutionMs).toBe(60000)
    expect(question.specs).toEqual([
      {
        id: "db",
        header: "Database",
        question: "Which DB?",
        options: [{ label: "Postgres", description: "SQL" }, { label: "Redis" }],
        allowsOther: true
      },
      {
        id: "envs",
        question: "Where?",
        options: [{ label: "dev" }, { label: "prod" }],
        multiSelect: true,
        allowsOther: true
      }
    ])
    expect(
      question.reply({
        outcome: "answered",
        answers: { db: { answers: ["Postgres"], note: "v16" }, envs: { answers: ["dev", "prod"] } }
      })
    ).toEqual({
      method: "userInput/answer",
      params: {
        commandId: expect.any(String),
        sessionId: "s-1",
        userInputId: "ui-1",
        answers: [
          { questionId: "db", selectedLabel: "Postgres", note: "v16" },
          { questionId: "envs", selectedLabels: ["dev", "prod"] }
        ]
      }
    })
    expect(
      question.reply({
        outcome: "answered",
        answers: { db: { answers: ["SQLite"] }, envs: { answers: ["dev", "staging"] } }
      }).params.answers
    ).toEqual([
      { questionId: "db", freeText: "SQLite" },
      { questionId: "envs", freeText: "dev\nstaging" }
    ])
    expect(question.reply({ outcome: "answered" }).params.answers).toEqual([
      { questionId: "db", freeText: "" },
      { questionId: "envs", selectedLabels: [] }
    ])
    expect(question.reply({ outcome: "cancelled" })).toEqual({
      method: "userInput/cancel",
      params: {
        commandId: expect.any(String),
        sessionId: "s-1",
        userInputId: "ui-1",
        reason: "The user dismissed the question."
      }
    })
    expect(
      userInputQuestion({ ...request, autoResolutionMs: undefined } as never).autoResolutionMs
    ).toBeUndefined()
  })
})
