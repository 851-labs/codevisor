import { describe, expect, it } from "vitest"
import {
  acpClientCapabilities,
  acpConfigSelection,
  acpPermissionOutcome,
  acpPermissionQuestion,
  extractPiStartupInfo,
  isPiStartupInfoNotification,
  normalizeAcpConfigOptions,
  normalizeModeState,
  piAssistantErrorFromSessionJsonl,
  runtimeEventFromNotification
} from "./index.js"

describe("@codevisor/agent-runtime", () => {
  it("requests Cursor's parameterized model controls without leaking proprietary metadata", () => {
    expect(acpClientCapabilities("cursor", true)).toEqual({
      _meta: { parameterizedModelPicker: true },
      plan: {},
      terminal: true
    })
    expect(acpClientCapabilities("grok-build", false)).toEqual({
      plan: {},
      terminal: false
    })
  })

  it("translates Codevisor's speed vocabulary to Cursor's native fast toggle", () => {
    expect(acpConfigSelection("cursor", "speed", "standard")).toEqual({
      configId: "fast",
      value: "false"
    })
    expect(acpConfigSelection("cursor", "speed", "fast")).toEqual({
      configId: "fast",
      value: "true"
    })
    expect(acpConfigSelection("gemini", "speed", "fast")).toEqual({
      configId: "speed",
      value: "fast"
    })
  })

  it("attaches diff stats to tool-call updates carrying diff content", () => {
    const event = runtimeEventFromNotification({
      sessionId: "session-1",
      update: {
        sessionUpdate: "tool_call_update",
        toolCallId: "tool-1",
        status: "completed",
        content: [
          {
            type: "diff",
            path: "/tmp/a.txt",
            oldText: "one\ntwo\n",
            newText: "one\nthree\nfour\n"
          }
        ]
      }
    } as never)

    expect(event.kind).toBe("session.output")
    expect(event.payload).toMatchObject({
      toolCallId: "tool-1",
      diffStats: [{ added: 2, path: "/tmp/a.txt", removed: 1 }]
    })

    const plain = runtimeEventFromNotification({
      sessionId: "session-1",
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "tool-2",
        title: "Read file"
      }
    } as never)
    expect(plain.payload).not.toHaveProperty("diffStats")
  })

  it("recognizes pi-acp startup info without matching ordinary agent output", () => {
    const startupInfo = "pi v0.80.9\n\nSkills\n\n- /tmp/SKILL.md\n"
    const response = {
      _meta: { piAcp: { startupInfo } },
      sessionId: "pi-session-1"
    }
    const startupNotification = {
      sessionId: "pi-session-1",
      update: {
        content: { text: startupInfo, type: "text" },
        sessionUpdate: "agent_message_chunk"
      }
    } as never
    const ordinaryNotification = {
      sessionId: "pi-session-1",
      update: {
        content: { text: "Here is the answer.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      }
    } as never

    expect(extractPiStartupInfo(response)).toBe(startupInfo)
    expect(isPiStartupInfoNotification(startupNotification, startupInfo)).toBe(true)
    expect(isPiStartupInfoNotification(ordinaryNotification, startupInfo)).toBe(false)
    expect(extractPiStartupInfo({ _meta: { piAcp: { startupInfo: null } } })).toBeUndefined()
  })

  it("recovers Pi provider errors that pi-acp reports as empty turns", () => {
    const providerError = JSON.stringify({
      type: "message",
      message: {
        role: "assistant",
        content: [],
        stopReason: "error",
        errorMessage: '400 {"type":"error","error":{"message":"Add extra usage and try again."}}'
      }
    })
    const successfulAssistant = JSON.stringify({
      type: "message",
      message: { role: "assistant", content: [{ type: "text", text: "Done" }], stopReason: "stop" }
    })

    expect(piAssistantErrorFromSessionJsonl(`{"type":"session"}\n${providerError}\n`)).toBe(
      "Add extra usage and try again."
    )
    expect(
      piAssistantErrorFromSessionJsonl(`{"type":"session"}\n${successfulAssistant}\n`)
    ).toBeUndefined()
    expect(
      piAssistantErrorFromSessionJsonl('{"type":"message","message":{"role":"user"}}\n')
    ).toBeUndefined()
  })

  it("removes redundant prefixes from ACP reasoning choices only", () => {
    const options = normalizeAcpConfigOptions([
      {
        category: "thought_level",
        currentValue: "low",
        id: "thinking_level",
        name: "Thinking",
        options: [
          { name: "Thinking: off", value: "off" },
          { name: "Thinking: low", value: "low" },
          { name: "Reasoning: high", value: "high" }
        ],
        type: "select"
      },
      {
        category: "model",
        currentValue: "thinking-model",
        id: "model",
        name: "Model",
        options: [{ name: "Thinking: model", value: "thinking-model" }],
        type: "select"
      }
    ] as never)

    expect(options[0]?.options.map((option) => option.name)).toEqual(["off", "low", "high"])
    expect(options[1]?.options.map((option) => option.name)).toEqual(["Thinking: model"])
  })

  it("normalizes Cursor's fast toggle into Speed and hides its context picker", () => {
    const options = normalizeAcpConfigOptions(
      [
        {
          category: "model",
          currentValue: "claude-opus-4-8",
          id: "model",
          name: "Model",
          options: [{ name: "Claude Opus 4.8", value: "claude-opus-4-8" }],
          type: "select"
        },
        {
          category: "thought_level",
          currentValue: "true",
          id: "thinking",
          name: "Thinking",
          options: [
            { name: "Off", value: "false" },
            { name: "On", value: "true" }
          ],
          type: "select"
        },
        {
          category: "thought_level",
          currentValue: "high",
          id: "effort",
          name: "Effort",
          options: [
            { name: "Low", value: "low" },
            { name: "High", value: "high" }
          ],
          type: "select"
        },
        {
          category: "model_config",
          currentValue: "200000",
          id: "context",
          name: "Context",
          options: [{ name: "200k", value: "200000" }],
          type: "select"
        },
        {
          category: "model_config",
          currentValue: "false",
          id: "fast",
          name: "Fast",
          options: [
            { name: "Off", value: "false" },
            { name: "On", value: "true" }
          ],
          type: "select"
        }
      ] as never,
      "cursor"
    )

    expect(options.map(({ category, id }) => ({ category, id }))).toEqual([
      { category: "model", id: "model" },
      { category: "thought_level", id: "thinking" },
      { category: "thought_level", id: "effort" },
      { category: "speed", id: "speed" }
    ])
    expect(options.at(-1)).toMatchObject({
      currentValue: "standard",
      name: "Speed",
      options: [
        { name: "Standard", value: "standard" },
        { name: "Fast", value: "fast" }
      ]
    })
  })

  it("maps ACP permission requests onto questions and answers back onto option ids", () => {
    const params = {
      options: [
        { kind: "allow_once", name: "Yes, and manually approve edits", optionId: "default" },
        { kind: "reject_once", name: "No, keep planning", optionId: "plan" }
      ],
      sessionId: "session-1",
      toolCall: {
        content: [{ content: { text: "# The Plan\n\n1. Do it", type: "text" }, type: "content" }],
        kind: "switch_mode",
        title: "Ready to code?",
        toolCallId: "exit-plan-1"
      }
    }
    const question = acpPermissionQuestion(params)
    expect(question?.sessionId).toBe("session-1")
    expect(question?.planDocument).toBe("# The Plan\n\n1. Do it")
    expect(question?.spec).toEqual({
      allowsOther: false,
      id: "permission",
      options: [{ label: "Yes, and manually approve edits" }, { label: "No, keep planning" }],
      question: "Ready to code?"
    })

    const optionIds = question!.optionIds
    expect(
      acpPermissionOutcome(optionIds, {
        answers: { permission: { answers: ["No, keep planning"] } },
        outcome: "answered"
      })
    ).toEqual({ outcome: { optionId: "plan", outcome: "selected" } })
    expect(acpPermissionOutcome(optionIds, { outcome: "cancelled" })).toEqual({
      outcome: { outcome: "cancelled" }
    })
    // Unknown labels degrade to cancelled rather than guessing.
    expect(
      acpPermissionOutcome(optionIds, {
        answers: { permission: { answers: ["Nonsense"] } },
        outcome: "answered"
      })
    ).toEqual({ outcome: { outcome: "cancelled" } })

    // Requests without options (or malformed ones) auto-cancel.
    expect(acpPermissionQuestion({ options: [], sessionId: "s" })).toBeUndefined()
    expect(acpPermissionQuestion("nope")).toBeUndefined()
    // Non-plan tool calls carry no plan document and fall back to a generic
    // question when untitled.
    const generic = acpPermissionQuestion({
      options: [{ kind: "allow_once", name: "Allow", optionId: "ok" }],
      sessionId: "s",
      toolCall: { kind: "execute", toolCallId: "t1" }
    })
    expect(generic?.planDocument).toBeUndefined()
    expect(generic?.spec.question).toBe("Allow the agent to proceed?")
  })

  it("maps agent-defined ACP modes onto the canonical vocabulary heuristically", () => {
    const state = normalizeModeState({
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Default" },
        { id: "plan", name: "Plan mode", description: "think first" },
        { id: "readOnly", name: "Read Only" },
        { id: "acceptEdits", name: "Accept Edits" },
        { id: "yolo", name: "YOLO" },
        { id: "goal", name: "Goal mode" }
      ]
    })
    expect(state.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "ask",
      "plan",
      "readOnly",
      "autoEdit",
      "fullAccess",
      undefined
    ])
    // Descriptions still pass through untouched.
    expect(state.availableModes[1]?.description).toBe("think first")
  })
})
