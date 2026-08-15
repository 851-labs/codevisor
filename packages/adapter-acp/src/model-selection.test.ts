import { describe, expect, it } from "vitest"
import {
  acpConfigOptionIds,
  acpModelConfigId,
  acpModelConfigOption,
  acpReasoningEffortConfigOption,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  usesAcpModelSelectionExtension
} from "./index.js"

describe("acp model-selection extension", () => {
  it("distinguishes a native model option from the optional model extension", () => {
    expect(
      acpConfigOptionIds({
        configOptions: [
          { id: "model", type: "select" },
          { id: "thought_level", type: "select" }
        ]
      })
    ).toEqual(new Set(["model", "thought_level"]))
    expect(acpConfigOptionIds({ models: { currentModelId: "gpt" } })).toEqual(new Set())
    expect(usesAcpModelSelectionExtension("model", new Set(["model"]))).toBe(false)
    expect(usesAcpModelSelectionExtension("model", new Set(["thought_level"]))).toBe(true)
    expect(usesAcpModelSelectionExtension("thought_level", undefined)).toBe(false)
  })

  type ModelSetter = Parameters<typeof applyAcpModelSelection>[0]
  const fakeConnection = (
    request: (method: string, params: unknown) => Promise<unknown>
  ): ModelSetter => ({ agent: { request } }) as unknown as ModelSetter

  it("reads the models extension off a session/new response into a model picker", () => {
    const state = extractAcpModelState({
      sessionId: "s-1",
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
          { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      }
    })
    expect(state).toEqual({
      currentModelId: "grok-4.5",
      availableModels: [
        { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
        { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
      ]
    })
    expect(
      acpModelConfigOption({
        currentModelId: "grok-4.5",
        availableModels: [
          { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
          { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      })
    ).toEqual({
      category: "model",
      currentValue: "grok-4.5",
      id: acpModelConfigId,
      name: "Model",
      options: [
        { value: "grok-4.5", name: "Grok 4.5", description: "frontier" },
        { value: "grok-composer-2.5-fast", name: "Composer 2.5" }
      ]
    })
  })

  it("ignores responses without a well-formed models extension", () => {
    expect(extractAcpModelState(undefined)).toBeUndefined()
    expect(extractAcpModelState({})).toBeUndefined()
    expect(extractAcpModelState({ models: null })).toBeUndefined()
    expect(
      extractAcpModelState({ models: { currentModelId: 1, availableModels: [] } })
    ).toBeUndefined()
    expect(
      extractAcpModelState({ models: { currentModelId: "m", availableModels: "nope" } })
    ).toBeUndefined()
    // Entries without a string modelId are dropped; if none remain, treat the
    // extension as absent rather than surfacing an empty picker.
    expect(
      extractAcpModelState({
        models: { currentModelId: "m", availableModels: [{ name: "no id" }, 7] }
      })
    ).toBeUndefined()
  })

  it("falls back to the model id when an entry omits a display name", () => {
    expect(
      extractAcpModelState({
        models: { currentModelId: "m1", availableModels: [{ modelId: "m1" }] }
      })
    ).toEqual({ currentModelId: "m1", availableModels: [{ modelId: "m1", name: "m1" }] })
  })

  it("applies a model change via session/set_model and rebuilds the picker", async () => {
    const calls: Array<{ readonly method: string; readonly params: unknown }> = []
    const connection = fakeConnection(async (method, params) => {
      calls.push({ method, params })
      return { _meta: { model: { Ok: "grok-composer-2.5-fast" } } }
    })
    const states = new Map([
      [
        "s-1",
        {
          currentModelId: "grok-4.5",
          availableModels: [
            { modelId: "grok-4.5", name: "Grok 4.5" },
            { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
          ]
        }
      ]
    ])
    const options = await applyAcpModelSelection(
      connection,
      states,
      "s-1",
      "grok-composer-2.5-fast"
    )
    expect(calls).toEqual([
      {
        method: "session/set_model",
        params: { modelId: "grok-composer-2.5-fast", sessionId: "s-1" }
      }
    ])
    expect(options).toEqual([
      {
        category: "model",
        currentValue: "grok-composer-2.5-fast",
        id: acpModelConfigId,
        name: "Model",
        options: [
          { value: "grok-4.5", name: "Grok 4.5" },
          { value: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      }
    ])
    expect(states.get("s-1")?.currentModelId).toBe("grok-composer-2.5-fast")
  })

  it("falls back to a single-entry picker for a resumed session with no cached models", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Ok: "m2" } } }))
    const options = await applyAcpModelSelection(connection, new Map(), "s-2", "m2")
    expect(options).toEqual([
      {
        category: "model",
        currentValue: "m2",
        id: acpModelConfigId,
        name: "Model",
        options: [{ value: "m2", name: "m2" }]
      }
    ])
  })

  it("uses the requested model id when the setter omits an Ok value", async () => {
    const connection = fakeConnection(async () => ({}))
    const options = await applyAcpModelSelection(connection, new Map(), "s-3", "m3")
    expect(options[0]?.currentValue).toBe("m3")
  })

  it("throws when session/set_model reports a string error", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Err: "unknown model" } } }))
    await expect(applyAcpModelSelection(connection, new Map(), "s-4", "bogus")).rejects.toThrow(
      "session/set_model failed: unknown model"
    )
  })

  it("stringifies non-string set_model errors", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Err: { code: 42 } } } }))
    await expect(applyAcpModelSelection(connection, new Map(), "s-5", "bogus")).rejects.toThrow(
      'session/set_model failed: {"code":42}'
    )
  })

  it("maps Grok model metadata into a server-defined reasoning picker", async () => {
    const state = extractAcpModelState({
      _meta: {
        "x.ai/sessionConfig": {
          options: [{ category: "mode", id: "deep", label: "Deep", selected: true }]
        }
      },
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          {
            modelId: "grok-4.5",
            name: "Grok 4.5",
            _meta: {
              supportsReasoningEffort: true,
              reasoningEffort: "high",
              reasoningEfforts: [
                { value: "low", label: "Low Effort" },
                {
                  id: "deep",
                  value: "xhigh",
                  label: "Deep",
                  description: "Use maximum reasoning"
                }
              ]
            }
          }
        ]
      }
    })
    expect(state).toBeDefined()
    expect(acpReasoningEffortConfigOption(state!)).toEqual({
      category: "thought_level",
      currentValue: "deep",
      id: "reasoning_effort",
      name: "Reasoning",
      options: [
        { value: "low", name: "Low" },
        { value: "deep", name: "Deep", description: "Use maximum reasoning" }
      ]
    })

    const calls: Array<{ readonly method: string; readonly params: unknown }> = []
    const connection = fakeConnection(async (method, params) => {
      calls.push({ method, params })
      return { _meta: { model: { Ok: "grok-4.5" } } }
    })
    const options = await applyAcpReasoningEffortSelection(
      connection,
      new Map([["s-1", state!]]),
      "s-1",
      "low"
    )
    expect(calls).toEqual([
      {
        method: "session/set_model",
        params: {
          _meta: { reasoningEffort: "low" },
          modelId: "grok-4.5",
          sessionId: "s-1"
        }
      }
    ])
    expect(options[1]?.currentValue).toBe("low")
  })

  it("uses Grok's built-in reasoning levels when the model omits a menu", () => {
    const state = extractAcpModelState({
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          {
            modelId: "grok-4.5",
            name: "Grok 4.5",
            _meta: { supportsReasoningEffort: true, reasoningEffort: "medium" }
          }
        ]
      }
    })
    const reasoning = acpReasoningEffortConfigOption(state!)
    const values = reasoning?.options.flatMap((option) =>
      "group" in option ? option.options.map((nested) => nested.value) : [option.value]
    )
    expect(values).toEqual(["minimal", "low", "medium", "high", "xhigh"])
    expect(acpReasoningEffortConfigOption(state!)?.currentValue).toBe("medium")
  })
})
