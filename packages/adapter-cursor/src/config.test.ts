import { describe, expect, it } from "vitest"
import {
  cursorClientCapabilities,
  cursorConfigSelection,
  cursorSessionMetadata,
  normalizeCursorConfigOptions
} from "./config.js"

describe("Cursor ACP configuration", () => {
  it("advertises Cursor's parameterized model picker without dropping generic capabilities", () => {
    expect(cursorClientCapabilities({ plan: {}, terminal: true })).toEqual({
      _meta: { parameterizedModelPicker: true },
      plan: {},
      terminal: true
    })
  })

  it("maps Codevisor speed to Cursor's native boolean fast option", () => {
    expect(cursorConfigSelection("speed", "standard")).toEqual({
      configId: "fast",
      value: "false"
    })
    expect(cursorConfigSelection("speed", "fast")).toEqual({
      configId: "fast",
      value: "true"
    })
    expect(cursorConfigSelection("model", "gpt-5")).toEqual({
      configId: "model",
      value: "gpt-5"
    })
  })

  it("normalizes Cursor's fast toggle and hides its redundant context picker", () => {
    const options = normalizeCursorConfigOptions([
      {
        category: "model",
        currentValue: "claude-opus",
        id: "model",
        name: "Model",
        options: [{ name: "Claude Opus", value: "claude-opus" }]
      },
      {
        category: "model_config",
        currentValue: "200000",
        id: "context",
        name: "Context",
        options: [{ name: "200k", value: "200000" }]
      },
      {
        category: "model_config",
        currentValue: "false",
        id: "fast",
        name: "Fast",
        options: [
          { name: "Off", value: "false" },
          { name: "On", value: "true" }
        ]
      }
    ])

    expect(options.map(({ category, id }) => ({ category, id }))).toEqual([
      { category: "model", id: "model" },
      { category: "speed", id: "speed" }
    ])
    expect(options[1]).toMatchObject({
      currentValue: "standard",
      options: [
        { name: "Standard", value: "standard" },
        { name: "Fast", value: "fast" }
      ]
    })
  })

  it("maps Cursor's agent mode onto full access", () => {
    expect(
      cursorSessionMetadata({
        sessionId: "session-1",
        configOptions: [],
        modes: {
          currentModeId: "agent",
          availableModes: [
            { id: "agent", name: "Agent" },
            { id: "plan", name: "Plan", canonicalId: "plan" }
          ]
        }
      }).modes
    ).toEqual({
      currentModeId: "agent",
      availableModes: [
        { id: "agent", name: "Agent", canonicalId: "fullAccess" },
        { id: "plan", name: "Plan", canonicalId: "plan" }
      ]
    })
  })
})
