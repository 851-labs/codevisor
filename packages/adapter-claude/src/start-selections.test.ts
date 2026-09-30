import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  configUpdates,
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  RELEASE_MODELS,
  run
} from "./test-support.js"

afterEach(() => {
  vi.restoreAllMocks()
})

/// A Claude process starts on the chat's saved selections: the picker's
/// choice is the only thing that sets the model, never the CLI default.
describe("Claude start selections", () => {
  it("starts the process on the saved selections and reports them before init", async () => {
    const fake = new FakeQuery()
    const created = await run(
      makeProvider(fake).createSession(definition, "/tmp", async () => {}, undefined, undefined, {
        configSelections: { effort: "xhigh", model: "claude-fable-5", speed: "fast" }
      })
    )

    expect(fake.options).toMatchObject({
      model: "claude-fable-5",
      settings: { effortLevel: "xhigh", fastMode: true }
    })
    expect(created.metadata.configOptions).toEqual([
      expect.objectContaining({ currentValue: "claude-fable-5", id: "model" }),
      expect.objectContaining({ currentValue: "xhigh", id: "effort" }),
      expect.objectContaining({ currentValue: "fast", id: "speed" })
    ])
    // Already running it: no follow-up switch.
    expect(fake.models).toEqual([])
  })

  it("moves a process started on an older release's Fable id onto the current row", async () => {
    const fake = new FakeQuery()
    vi.spyOn(fake, "supportedModels").mockResolvedValue(RELEASE_MODELS)
    const created = await run(
      makeProvider(fake).createSession(definition, "/tmp", async () => {}, undefined, undefined, {
        configSelections: { model: "claude-fable-5[1m]" }
      })
    )

    expect(fake.options?.model).toBe("claude-fable-5[1m]")
    expect(fake.models).toEqual(["claude-fable-5-1[1m]"])
    expect(created.metadata.configOptions).toContainEqual(
      expect.objectContaining({ currentValue: "claude-fable-5-1[1m]", id: "model" })
    )
  })

  it("reports a CLI that starts on another model than it was given as a fallback", async () => {
    const fake = new FakeQuery()
    const events: Array<RuntimeEvent> = []
    await run(
      makeProvider(fake).createSession(
        definition,
        "/tmp",
        async (event) => {
          events.push(event)
        },
        undefined,
        undefined,
        { configSelections: { model: "claude-fable-5" } }
      )
    )
    fake.push(initMessage("sdk-session-1", "claude-opus-4-8"))
    await fake.drain()

    expect(events.map((event) => event.payload)).toContainEqual({
      modelFallback: {
        category: null,
        fallbackModel: "claude-opus-4-8",
        originalModel: "claude-fable-5"
      }
    })
    expect(configUpdates(events).at(-1)).toMatchObject({
      configId: "model",
      value: "claude-opus-4-8"
    })
  })
})
