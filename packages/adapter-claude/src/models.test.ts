import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  run,
  settle,
  systemMessage
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("normalizes malformed init model ids before updating config options", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const created = await run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage("sdk-session-1", "claude-fable-5\u001b[1m"))
    await settle()
    await run(created.handle.setConfigOption("speed", "fast"))

    const updated = events.at(-1)?.payload as {
      configOptions?: Array<{ currentValue: string; id: string }>
    }
    const model = updated.configOptions?.find((option) => option.id === "model")
    expect(model?.currentValue).toBe("claude-fable-5")
    const effort = updated.configOptions?.find((option) => option.id === "effort")
    expect(effort?.currentValue).toBe("high")
  })

  it("keeps the last known picker model when a later init reports an unknown model", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const created = await run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage("sdk-session-1", "claude-not-in-picker"))
    await settle()
    await run(created.handle.setConfigOption("speed", "fast"))

    const updated = events.at(-1)?.payload as {
      configOptions?: Array<{ currentValue: string; id: string }>
    }
    const model = updated.configOptions?.find((option) => option.id === "model")
    expect(model?.currentValue).toBe("claude-fable-5")
    const effort = updated.configOptions?.find((option) => option.id === "effort")
    expect(effort?.currentValue).toBe("high")
  })

  it("waits out a slow model list when the caller grants a budget", async () => {
    const fake = new FakeQuery()
    // Slower than instant, well within the granted inspection budget — the
    // race must use the caller's timeout, not the 3s interactive default.
    vi.spyOn(fake, "supportedModels").mockImplementation(
      () =>
        new Promise((resolve) =>
          setTimeout(
            () => resolve([{ description: "", displayName: "Sonnet", value: "sonnet" }]),
            10
          )
        )
    )
    const provider = makeProvider(fake)
    const created = await run(
      provider.createSession(definition, "/tmp", async () => {}, undefined, undefined, {
        modelListTimeoutMs: 5000
      })
    )
    const model = created.metadata.configOptions.find((option) => option.id === "model")
    expect(model?.options).toEqual([{ name: "Sonnet", value: "sonnet" }])
  })

  it("reconciles refusal fallback model ids with unambiguous picker aliases", async () => {
    const fake = new FakeQuery()
    vi.spyOn(fake, "supportedModels").mockResolvedValue([
      {
        description: "",
        displayName: "Fable",
        supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
        supportsEffort: true,
        value: "claude-fable-5"
      },
      { description: "", displayName: "Opus (1M context)", value: "opus[1m]" },
      { description: "", displayName: "Sonnet", value: "sonnet" },
      { description: "", displayName: "Haiku", value: "haiku" }
    ])
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("model_refusal_fallback", {
        api_refusal_category: "cyber",
        fallback_model: "claude-opus-4-8",
        original_model: "claude-fable-5"
      })
    )
    await settle()

    const updates = events
      .filter((event) => event.kind === "session.updated")
      .map((event) => event.payload as Record<string, unknown>)
    expect(updates).toContainEqual({
      modelFallback: {
        category: "cyber",
        fallbackModel: "opus[1m]",
        originalModel: "claude-fable-5"
      }
    })
    expect(updates).toContainEqual(
      expect.objectContaining({
        configId: "model",
        value: "opus[1m]",
        configOptions: expect.arrayContaining([
          expect.objectContaining({ currentValue: "opus[1m]", id: "model" })
        ])
      })
    )
  })

  it("reports an unknown refusal fallback without relabeling it as the current model", async () => {
    const fake = new FakeQuery()
    vi.spyOn(fake, "supportedModels").mockResolvedValue([
      { description: "", displayName: "Fable", value: "claude-fable-5" }
    ])
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("model_refusal_fallback", {
        fallback_model: "claude-unknown-fallback-1",
        original_model: "claude-fable-5"
      })
    )
    await settle()

    expect(events.map((event) => event.payload)).toContainEqual({
      modelFallback: {
        category: null,
        fallbackModel: "claude-unknown-fallback-1",
        originalModel: "claude-fable-5"
      }
    })
  })

  it("exposes speed for fast-mode models and applies it via flag settings", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const speed = created.metadata.configOptions.find((option) => option.id === "speed")
    expect(speed).toMatchObject({ category: "speed", currentValue: "standard", name: "Speed" })
    expect(speed?.options.map((option) => ("value" in option ? option.value : undefined))).toEqual([
      "standard",
      "fast"
    ])

    await run(created.handle.setConfigOption("speed", "fast"))
    expect(fake.flagSettings).toEqual([{ fastMode: true }])
    const updated = events.at(-1)?.payload as Record<string, unknown>
    expect(updated.configId).toBe("speed")
    expect(updated.configOptions).toContainEqual(
      expect.objectContaining({ currentValue: "fast", id: "speed" })
    )

    // Switching to a model without fast mode drops the option and turns
    // fast mode off.
    await run(created.handle.setConfigOption("model", "claude-opus-4-8"))
    expect(fake.flagSettings).toEqual([{ fastMode: true }, { fastMode: false }])
    const afterModel = events.at(-1)?.payload as Record<string, unknown>
    expect(afterModel.configOptions).not.toContainEqual(expect.objectContaining({ id: "speed" }))
  })

  it("seeds the speed from the init message's fast mode state", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push({ ...(initMessage() as object), fast_mode_state: "on" } as never)
    const created = await createPromise

    // The init lands after createSession's metadata snapshot in some orders;
    // read the live options through a config change instead.
    await run(created.handle.setConfigOption("effort", "medium"))
    const updated = events.at(-1)?.payload as Record<string, unknown>
    const speed = (
      updated.configOptions as Array<{ id: string; currentValue: string }> | undefined
    )?.find((option) => option.id === "speed")
    expect(speed?.currentValue).toBe("fast")
  })
})
