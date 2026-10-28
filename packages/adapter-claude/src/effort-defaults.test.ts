import type { BaseHookInput, HookInput } from "@anthropic-ai/claude-agent-sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  configUpdates,
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  recordsValue,
  RELEASE_MODELS,
  run
} from "./test-support.js"

afterEach(() => {
  vi.restoreAllMocks()
})

const SONNET = "sonnet"
const FABLE = "claude-fable-5-1[1m]"

const listingQuery = (): FakeQuery => {
  const fake = new FakeQuery()
  vi.spyOn(fake, "supportedModels").mockResolvedValue(RELEASE_MODELS)
  return fake
}

const chainedQueries = (count: number): Array<FakeQuery> => {
  const queries = Array.from({ length: count }, listingQuery)
  queries[0]!.successors.push(...queries.slice(1))
  return queries
}

const hookInput = (
  event: "PreToolUse" | "PostToolUse" | "Stop",
  base: BaseHookInput
): HookInput => {
  if (event === "Stop") return { ...base, hook_event_name: "Stop", stop_hook_active: false }
  const tool = { tool_input: { command: "ls" }, tool_name: "Bash", tool_use_id: "tool-1" }
  if (event === "PreToolUse") return { ...base, ...tool, hook_event_name: "PreToolUse" }

  return { ...base, ...tool, hook_event_name: "PostToolUse", tool_response: "" }
}

const reportEffort = async (
  fake: FakeQuery,
  event: "PreToolUse" | "PostToolUse" | "Stop",
  level: string,
  agentId?: string
): Promise<void> => {
  const base = {
    cwd: "/tmp",
    effort: { level },
    session_id: "sdk-session-1",
    transcript_path: "/tmp/transcript",
    ...(agentId === undefined ? {} : { agent_id: agentId })
  }
  const input = hookInput(event, base)
  const hook = fake.options?.hooks?.[event]?.[0]?.hooks[0]
  await hook?.(input, undefined, { signal: new AbortController().signal })
}

const effortOf = (configOptions: unknown): unknown =>
  recordsValue(configOptions).find((option) => option.id === "effort")?.currentValue

const startOn = async (
  provider: ReturnType<typeof makeProvider>,
  fake: FakeQuery,
  model: string,
  configSelections?: Record<string, string>
) => {
  const events: Array<RuntimeEvent> = []
  const started = run(
    provider.createSession(
      definition,
      "/tmp",
      async (event) => {
        events.push(event)
      },
      undefined,
      undefined,
      configSelections === undefined ? undefined : { configSelections }
    )
  )
  fake.push(initMessage("sdk-session-1", model))
  const created = await started
  await fake.drain()
  return { created, events }
}

describe("Claude effort defaults", () => {
  it("shows the effort the CLI reports and starts later sessions on it explicitly", async () => {
    const [first, second] = chainedQueries(2)
    const provider = makeProvider(first!)
    const { created, events } = await startOn(provider, first!, SONNET)
    expect(first!.options?.settings).toBeUndefined()
    expect(effortOf(created.metadata.configOptions)).toBe("high")

    await reportEffort(first!, "Stop", "medium")

    expect(configUpdates(events).at(-1)).toMatchObject({ configId: "effort", value: "medium" })
    expect(effortOf(configUpdates(events).at(-1)?.configOptions)).toBe("medium")
    const later = await startOn(provider, second!, SONNET)
    expect(second!.options?.settings).toEqual({ effortLevel: "medium" })
    expect(effortOf(later.created.metadata.configOptions)).toBe("medium")
  })

  it("learns the effort before the first tool runs, not after it", async () => {
    const [first] = chainedQueries(1)
    const { events } = await startOn(makeProvider(first!), first!, SONNET)
    const updatesBefore = configUpdates(events).length

    await reportEffort(first!, "PostToolUse", "low")
    expect(configUpdates(events)).toHaveLength(updatesBefore)

    await reportEffort(first!, "PreToolUse", "low")
    expect(effortOf(configUpdates(events).at(-1)?.configOptions)).toBe("low")
  })

  it("keeps a picked effort when the CLI reports another level", async () => {
    const [first, second] = chainedQueries(2)
    const provider = makeProvider(first!)
    const { events } = await startOn(provider, first!, SONNET, { effort: "low" })
    const updatesBefore = configUpdates(events).length

    await reportEffort(first!, "PreToolUse", "medium")

    expect(configUpdates(events)).toHaveLength(updatesBefore)
    await startOn(provider, second!, SONNET)
    expect(second!.options?.settings).toBeUndefined()
  })

  it("ignores effort reported from inside a sub-agent", async () => {
    const [first, second] = chainedQueries(2)
    const provider = makeProvider(first!)
    const { events } = await startOn(provider, first!, SONNET)
    const updatesBefore = configUpdates(events).length

    await reportEffort(first!, "PreToolUse", "low", "subagent-1")

    expect(configUpdates(events)).toHaveLength(updatesBefore)
    await startOn(provider, second!, SONNET)
    expect(second!.options?.settings).toBeUndefined()
  })

  it("moves an unpicked effort to each model's own default when the model changes", async () => {
    const [fable, sonnet] = chainedQueries(2)
    const provider = makeProvider(fable!)
    await startOn(provider, fable!, FABLE, { model: FABLE })
    await reportEffort(fable!, "PreToolUse", "high")
    const { created } = await startOn(provider, sonnet!, SONNET)
    await reportEffort(sonnet!, "Stop", "medium")

    const onFable = await run(created.handle.setConfigOption("model", FABLE))
    expect(sonnet!.flagSettings.at(-1)).toEqual({ effortLevel: "high" })
    expect(effortOf(onFable)).toBe("high")

    await run(created.handle.setConfigOption("model", "haiku"))
    expect(sonnet!.flagSettings.at(-1)).toEqual({ effortLevel: null })

    const flagsBefore = sonnet!.flagSettings.length
    await run(created.handle.setConfigOption("model", "opus"))
    expect(sonnet!.flagSettings).toHaveLength(flagsBefore)
  })

  it("stops following model defaults once an effort is picked", async () => {
    const [fable, sonnet] = chainedQueries(2)
    const provider = makeProvider(fable!)
    await startOn(provider, fable!, FABLE, { model: FABLE })
    await reportEffort(fable!, "Stop", "high")
    const { created } = await startOn(provider, sonnet!, SONNET)

    await run(created.handle.setConfigOption("effort", "low"))
    const flagsBefore = sonnet!.flagSettings.length
    const onFable = await run(created.handle.setConfigOption("model", FABLE))

    expect(sonnet!.flagSettings).toHaveLength(flagsBefore)
    expect(effortOf(onFable)).toBe("low")
  })
})
