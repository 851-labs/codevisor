import type { SessionConfigOption, SessionModeState } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeAgentRuntime } from "./index.js"
import type {
  AgentProvider,
  AgentRuntimeError,
  AgentSessionHandle,
  AgentSessionMetadata,
  RuntimeEmit,
  RuntimeEvent
} from "./types.js"

const harnessModes: SessionModeState = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Always Ask", canonicalId: "ask" },
    { id: "plan", name: "Plan", canonicalId: "plan" },
    { id: "plan-lite", name: "Light planning" },
    { id: "architect", name: "Planner" },
    { id: "bypassPermissions", name: "Bypass Permissions", canonicalId: "fullAccess" }
  ]
}

const modeOption: SessionConfigOption = {
  id: "agent",
  name: "Agent",
  category: "mode",
  currentValue: "build",
  options: [
    { value: "build", name: "Build" },
    { value: "plan", name: "Plan" },
    { value: "review", name: "Planning review" }
  ]
}

const groupedModeOption: SessionConfigOption = {
  id: "mode",
  name: "Mode",
  currentValue: "build",
  options: [
    {
      group: "core",
      name: "Core",
      options: [
        { value: "build", name: "Build" },
        { value: "plan", name: "Plan" }
      ]
    }
  ]
}

const modelOption: SessionConfigOption = {
  id: "model",
  name: "Model",
  category: "model",
  currentValue: "planck",
  options: [{ value: "planck", name: "Planck" }]
}

interface FakeHarness {
  readonly modes?: SessionModeState | null
  readonly steers?: boolean
  readonly failingModes?: ReadonlyArray<string>
  readonly startupEvents?: ReadonlyArray<RuntimeEvent>
}

interface FakeCalls {
  readonly modes: Array<string>
  readonly configPicks: Array<string>
  readonly prompts: Array<string>
  readonly steers: Array<string>
  readonly goals: Array<string>
  emit: RuntimeEmit
}

const fakeHarness = (harness: FakeHarness = {}) => {
  const calls: FakeCalls = {
    modes: [],
    configPicks: [],
    prompts: [],
    steers: [],
    goals: [],
    emit: () => Promise.resolve()
  }
  const handle: AgentSessionHandle = {
    prompt: (input) =>
      Effect.sync(() => {
        calls.prompts.push(typeof input === "string" ? input : input.text)
        return { stopReason: "end_turn" }
      }),
    ...(harness.steers === false
      ? {}
      : {
          steer: (input) =>
            Effect.sync(() => {
              calls.steers.push(typeof input === "string" ? input : input.text)
              return true
            })
        }),
    cancel: Effect.succeed({ runtimeState: "reusable" }),
    setMode: (modeId) => {
      calls.modes.push(modeId)
      if (harness.failingModes?.includes(modeId) === true) return Effect.die("mode switch failed")
      return Effect.promise(() =>
        calls.emit({ kind: "session.updated", subjectId: "agent-1", payload: { modeId } })
      )
    },
    setConfigOption: (configId, value) =>
      Effect.sync(() => {
        calls.configPicks.push(`${configId}=${value}`)
        return [modeOption, modelOption]
      }),
    setGoal: (update) =>
      Effect.sync(() => {
        calls.goals.push(update.objective ?? "")
        return {
          objective: update.objective ?? "",
          status: "active",
          tokenBudget: null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: "2026-10-28T00:00:00.000Z",
          updatedAt: "2026-10-28T00:00:00.000Z"
        }
      }),
    close: Effect.void
  }
  const metadata: AgentSessionMetadata = {
    sessionId: "agent-1",
    ...(harness.modes === null ? {} : { modes: harness.modes ?? harnessModes }),
    configOptions: [modeOption, groupedModeOption, modelOption],
    supportsGoals: true
  }
  const start = (emit: RuntimeEmit) =>
    Effect.promise(async () => {
      calls.emit = emit
      for (const event of harness.startupEvents ?? []) await emit(event)
      return { handle, metadata, sessionId: "agent-1" }
    })
  const provider: AgentProvider = {
    id: "claude",
    readiness: () => ({ state: "ready" }),
    createSession: (_definition, _cwd, emit) => start(emit),
    loadSession: (_definition, _agentSessionId, _cwd, emit) => start(emit)
  }
  return { calls, provider }
}

const startSession = async (
  harness: FakeHarness,
  bot: boolean,
  how: "create" | "load" = "create"
) => {
  const fake = fakeHarness(harness)
  const runtime = makeAgentRuntime({ env: { PATH: "/bin" }, providers: { claude: fake.provider } })
  const delivered: Array<RuntimeEvent> = []
  const sink = (event: RuntimeEvent) => {
    delivered.push(event)
  }
  const options = bot ? { bot } : undefined
  let metadata: AgentSessionMetadata
  if (how === "create") {
    await Effect.runPromise(
      runtime.createAgentSession("claude-code", "/tmp/bot", sink, undefined, undefined, options)
    )
    metadata = await Effect.runPromise(
      runtime.loadAgentSession("claude-code", "agent-1", "/tmp/bot", sink)
    )
  } else {
    metadata = await Effect.runPromise(
      runtime.loadAgentSession(
        "claude-code",
        "agent-1",
        "/tmp/bot",
        sink,
        undefined,
        undefined,
        options
      )
    )
  }
  return { ...fake, runtime, metadata, delivered }
}

const settled = <A>(effect: Effect.Effect<A, AgentRuntimeError>) =>
  Effect.runPromise(Effect.result(effect)).then((result) =>
    result._tag === "Success" ? "ok" : result.failure.message
  )

const choiceValues = (option: SessionConfigOption | undefined): ReadonlyArray<string> =>
  (option?.options ?? []).flatMap((entry) =>
    "group" in entry ? entry.options.map((choice) => choice.value) : [entry.value]
  )

describe("bot sessions", () => {
  it("start without plan modes, plan choices, or goals, while other chats keep them", async () => {
    const bot = await startSession({}, true)
    const chat = await startSession({}, false)

    expect(bot.metadata.supportsGoals).toBe(false)
    expect(bot.metadata.modes?.availableModes.map((mode) => mode.id)).toEqual([
      "default",
      "bypassPermissions"
    ])
    expect(
      choiceValues(bot.metadata.configOptions.find((option) => option.id === "agent"))
    ).toEqual(["build"])
    expect(choiceValues(bot.metadata.configOptions.find((option) => option.id === "mode"))).toEqual(
      ["build"]
    )
    expect(
      choiceValues(bot.metadata.configOptions.find((option) => option.id === "model"))
    ).toEqual(["planck"])
    expect(chat.metadata.supportsGoals).toBe(true)
    expect(chat.metadata.modes?.availableModes).toHaveLength(5)
  })

  it("refuses plan mode, goals, and plan or goal commands, and lets everything else through", async () => {
    const { runtime, calls } = await startSession({}, true)

    expect(await settled(runtime.setMode("agent-1", "plan"))).toBe("Bots can't use plan mode")
    expect(await settled(runtime.setMode("agent-1", "architect"))).toBe("Bots can't use plan mode")
    expect(await settled(runtime.setMode("agent-1", "bypassPermissions"))).toBe("ok")
    expect(await settled(runtime.setConfigOption("agent-1", "agent", "plan"))).toBe(
      "Bots can't use plan mode"
    )
    expect(await settled(runtime.setConfigOption("agent-1", "mode", "Plan"))).toBe(
      "Bots can't use plan mode"
    )
    expect(await settled(runtime.setConfigOption("agent-1", "model", "planck"))).toBe("ok")
    expect(await settled(runtime.setGoal("agent-1", { objective: "Ship it" }))).toBe(
      "Bots can't use goals"
    )
    expect(await settled(runtime.prompt("agent-1", "/goal ship the release"))).toBe(
      "Bots can't use plan mode or goals"
    )
    expect(await settled(runtime.prompt("agent-1", { text: "  /PLAN" }))).toBe(
      "Bots can't use plan mode or goals"
    )
    expect(await settled(runtime.steer!("agent-1", "/plan"))).toBe(
      "Bots can't use plan mode or goals"
    )
    expect(await settled(runtime.prompt("agent-1", "/planner check the goal"))).toBe("ok")
    expect(await settled(runtime.steer!("agent-1", { text: "plan the next step" }))).toBe("ok")

    expect(calls).toMatchObject({
      modes: ["bypassPermissions"],
      configPicks: ["model=planck"],
      prompts: ["/planner check the goal"],
      steers: ["plan the next step"],
      goals: []
    })
  })

  it("keeps steering unavailable when the harness can't steer", async () => {
    const { runtime } = await startSession({ steers: false }, true)

    expect(await Effect.runPromise(runtime.steer!("agent-1", "/plan"))).toBe(false)
  })

  it("switches back to the working mode when the harness puts a bot in plan mode", async () => {
    const { calls, delivered } = await startSession({}, true)

    await calls.emit({
      kind: "session.output",
      subjectId: "agent-1",
      payload: { sessionUpdate: "current_mode_update", currentModeId: "bypassPermissions" }
    })
    await calls.emit({
      kind: "session.output",
      subjectId: "agent-1",
      payload: { sessionUpdate: "current_mode_update", currentModeId: "plan" }
    })
    await calls.emit({
      kind: "session.updated",
      subjectId: "agent-1",
      payload: { modeId: "plan-lite" }
    })

    expect(calls.modes).toEqual(["bypassPermissions", "bypassPermissions"])
    expect(delivered.map((event) => event.payload)).toContainEqual({ modeId: "bypassPermissions" })
  })

  it("strips plan choices and plan or goal commands from harness updates", async () => {
    const { calls, delivered } = await startSession({}, true)

    await calls.emit({
      kind: "session.output",
      subjectId: "agent-1",
      payload: { sessionUpdate: "config_option_update", configOptions: [modeOption] }
    })
    await calls.emit({
      kind: "session.output",
      subjectId: "agent-1",
      payload: {
        sessionUpdate: "available_commands_update",
        availableCommands: [{ name: "goal" }, { name: "Plan" }, { name: "review" }, "bare"]
      }
    })
    await calls.emit({ kind: "session.output", subjectId: "agent-1", payload: "raw" })
    await calls.emit({
      kind: "session.output",
      subjectId: "agent-1",
      payload: { sessionUpdate: "plan", entries: [] }
    })

    expect(delivered.map((event) => event.payload)).toEqual([
      {
        sessionUpdate: "config_option_update",
        configOptions: [{ ...modeOption, options: [modeOption.options[0]] }]
      },
      {
        sessionUpdate: "available_commands_update",
        availableCommands: [{ name: "review" }, "bare"]
      },
      "raw",
      { sessionUpdate: "plan", entries: [] }
    ])
  })

  it.each([
    {
      name: "a resumed bot in plan mode moves to full access",
      modes: { ...harnessModes, currentModeId: "plan" },
      expected: ["bypassPermissions"],
      current: "bypassPermissions"
    },
    {
      name: "a resumed bot in plan mode without full access moves to the first other mode",
      modes: {
        currentModeId: "plan",
        availableModes: [
          { id: "plan", name: "Plan" },
          { id: "default", name: "Default" }
        ]
      },
      expected: ["default"],
      current: "default"
    },
    {
      name: "a harness that only offers plan mode is left alone",
      modes: { currentModeId: "plan", availableModes: [{ id: "plan", name: "Plan" }] },
      expected: [],
      current: "plan"
    }
  ])("$name", async ({ modes, expected, current }) => {
    const { calls, metadata } = await startSession({ modes }, true, "load")

    expect(calls.modes).toEqual(expected)
    expect(metadata.modes?.currentModeId).toBe(current)
  })

  it("leaves harnesses without modes alone, even when they announce plan mode", async () => {
    const { calls, metadata } = await startSession(
      {
        modes: null,
        startupEvents: [
          { kind: "session.updated", subjectId: "agent-1", payload: { modeId: "plan" } }
        ]
      },
      true,
      "load"
    )

    await calls.emit({ kind: "session.updated", subjectId: "agent-1", payload: { modeId: "plan" } })

    expect(metadata.modes).toBeUndefined()
    expect(calls.modes).toEqual([])
  })

  it("keeps the bot running when switching out of plan mode fails", async () => {
    const { calls } = await startSession(
      { modes: { ...harnessModes, currentModeId: "plan" }, failingModes: ["bypassPermissions"] },
      true,
      "load"
    )

    expect(calls.modes).toEqual(["bypassPermissions"])
  })
})
