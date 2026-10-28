import type {
  SessionConfigOption,
  SessionConfigSelectGroup,
  SessionConfigSelectOption,
  SessionMode,
  SessionModeState
} from "@codevisor/api"
import { isRecord } from "@codevisor/api"
import { Effect } from "effect"

import {
  AgentRuntimeError,
  normalizePromptInput,
  type AgentSessionHandle,
  type AgentSessionMetadata,
  type CreateSessionOptions,
  type PromptInput,
  type RuntimeEmit,
  type RuntimeEvent
} from "./types.js"

export const BOT_PLAN_MODE_REFUSAL = "Bots can't use plan mode"
export const BOT_GOAL_REFUSAL = "Bots can't use goals"
export const BOT_PLAN_OR_GOAL_REFUSAL = "Bots can't use plan mode or goals"

export interface GuardedSession {
  readonly metadata: AgentSessionMetadata
  readonly handle: AgentSessionHandle
}

export interface SessionGuard {
  readonly emit: (emit: RuntimeEmit) => RuntimeEmit
  readonly adopt: (session: GuardedSession) => GuardedSession
}

export const isPlanModeId = (modeId: string): boolean => planPattern.test(modeId)

export const isPlanOrGoalCommand = (text: string): boolean => planOrGoalCommand.test(text)

export const sessionGuardFor = (options: CreateSessionOptions | undefined): SessionGuard => {
  if (options?.bot !== true) return unguarded
  return makeBotSessionGuard()
}

export const announcedModeId = (event: RuntimeEvent): string | undefined => {
  if (!isRecord(event.payload)) return undefined
  const payload = event.payload
  if (event.kind === "session.updated" && typeof payload.modeId === "string") return payload.modeId
  if (!isCurrentModeUpdate(event, payload)) return undefined
  return typeof payload.currentModeId === "string" ? payload.currentModeId : undefined
}

const planPattern = /^plan/i
const planOrGoalCommand = /^\s*\/(plan|goal)(\s|$)/i
const planOrGoalCommandName = /^(plan|goal)$/i

const unguarded: SessionGuard = {
  emit: (emit) => emit,
  adopt: (session) => session
}

interface BotGuardState {
  handle: AgentSessionHandle | undefined
  modeOptionIds: ReadonlySet<string>
  planModeIds: ReadonlySet<string>
  workingModeId: string | undefined
}

const makeBotSessionGuard = (): SessionGuard => {
  const state: BotGuardState = {
    handle: undefined,
    modeOptionIds: new Set(),
    planModeIds: new Set(),
    workingModeId: undefined
  }
  return {
    emit: (emit) => (event) => {
      followModeChange(state, event)
      return emit(withoutPlanOrGoalChoices(event))
    },
    adopt: (session) => {
      state.handle = session.handle
      state.modeOptionIds = modeOptionIdsOf(session.metadata.configOptions)
      state.planModeIds = planModeIdsOf(session.metadata.modes)
      state.workingModeId = workingModeOf(session.metadata.modes)
      if (isPlanModeOf(state, session.metadata.modes?.currentModeId)) leavePlanMode(state)
      return {
        metadata: botMetadata(session.metadata, state.workingModeId),
        handle: botHandle(session.handle, state)
      }
    }
  }
}

const followModeChange = (state: BotGuardState, event: RuntimeEvent): void => {
  const modeId = announcedModeId(event)
  if (modeId === undefined) return
  if (isPlanModeOf(state, modeId)) {
    leavePlanMode(state)
    return
  }

  state.workingModeId = modeId
}

const leavePlanMode = (state: BotGuardState): void => {
  const { handle, workingModeId } = state
  if (handle === undefined || workingModeId === undefined) return
  void Effect.runPromise(handle.setMode(workingModeId)).catch(() => undefined)
}

const isPlanModeOf = (state: BotGuardState, modeId: string | undefined): boolean =>
  modeId !== undefined && (state.planModeIds.has(modeId) || isPlanModeId(modeId))

const isPlanMode = (mode: SessionMode): boolean =>
  mode.canonicalId === "plan" || isPlanModeId(mode.id) || planPattern.test(mode.name)

const planModeIdsOf = (modes: SessionModeState | undefined): ReadonlySet<string> =>
  new Set((modes?.availableModes ?? []).filter(isPlanMode).map((mode) => mode.id))

const workingModeOf = (modes: SessionModeState | undefined): string | undefined => {
  const usable = (modes?.availableModes ?? []).filter((mode) => !isPlanMode(mode))
  const current = usable.find((mode) => mode.id === modes?.currentModeId)
  const fullAccess = usable.find((mode) => mode.canonicalId === "fullAccess")
  return (current ?? fullAccess ?? usable[0])?.id
}

const botMetadata = (
  metadata: AgentSessionMetadata,
  workingModeId: string | undefined
): AgentSessionMetadata => ({
  ...metadata,
  ...(metadata.modes === undefined
    ? {}
    : { modes: withoutPlanModes(metadata.modes, workingModeId) }),
  configOptions: withoutPlanConfigChoices(metadata.configOptions),
  supportsGoals: false
})

const withoutPlanModes = (
  modes: SessionModeState,
  workingModeId: string | undefined
): SessionModeState => ({
  currentModeId: workingModeId ?? modes.currentModeId,
  availableModes: modes.availableModes.filter((mode) => !isPlanMode(mode))
})

const botHandle = (handle: AgentSessionHandle, state: BotGuardState): AgentSessionHandle => ({
  ...handle,
  prompt: (input) => refuseCommand("prompt", input) ?? handle.prompt(input),
  ...(handle.steer === undefined ? {} : { steer: botSteer(handle.steer) }),
  setMode: (modeId) => {
    if (isPlanModeOf(state, modeId)) return refusal("setMode", BOT_PLAN_MODE_REFUSAL)
    return handle.setMode(modeId)
  },
  setConfigOption: (configId, value) => {
    if (isPlanPick(state, configId, value)) {
      return refusal("setConfigOption", BOT_PLAN_MODE_REFUSAL)
    }
    return handle.setConfigOption(configId, value)
  },
  setGoal: () => refusal("setGoal", BOT_GOAL_REFUSAL)
})

const botSteer =
  (steer: NonNullable<AgentSessionHandle["steer"]>) =>
  (input: string | PromptInput): Effect.Effect<boolean, AgentRuntimeError> =>
    refuseCommand("steer", input) ?? steer(input)

const refuseCommand = (
  operation: string,
  input: string | PromptInput
): Effect.Effect<never, AgentRuntimeError> | undefined => {
  if (!isPlanOrGoalCommand(normalizePromptInput(input).text)) return undefined
  return refusal(operation, BOT_PLAN_OR_GOAL_REFUSAL)
}

const refusal = (operation: string, message: string): Effect.Effect<never, AgentRuntimeError> =>
  Effect.fail(new AgentRuntimeError({ operation, message }))

const withoutPlanOrGoalChoices = (event: RuntimeEvent): RuntimeEvent => {
  if (!isRecord(event.payload)) return event
  const { availableCommands, configOptions } = event.payload
  if (Array.isArray(configOptions)) {
    return {
      ...event,
      payload: { ...event.payload, configOptions: withoutPlanConfigChoices(configOptions) }
    }
  }
  if (isCommandsUpdate(event.payload) && Array.isArray(availableCommands)) {
    return {
      ...event,
      payload: { ...event.payload, availableCommands: availableCommands.filter(isNotPlanOrGoal) }
    }
  }
  return event
}

const isCurrentModeUpdate = (event: RuntimeEvent, payload: Record<string, unknown>): boolean =>
  event.kind === "session.output" && payload.sessionUpdate === "current_mode_update"

const isCommandsUpdate = (payload: Record<string, unknown>): boolean =>
  payload.sessionUpdate === "available_commands_update"

const isNotPlanOrGoal = (command: unknown): boolean =>
  !(
    isRecord(command) &&
    typeof command.name === "string" &&
    planOrGoalCommandName.test(command.name)
  )

const isModeOption = (option: SessionConfigOption): boolean =>
  option.category === "mode" || option.id === "mode"

const modeOptionIdsOf = (options: ReadonlyArray<SessionConfigOption>): ReadonlySet<string> =>
  new Set(["mode", ...options.filter(isModeOption).map((option) => option.id)])

const isPlanPick = (state: BotGuardState, configId: string, value: string): boolean =>
  state.modeOptionIds.has(configId) && isPlanModeId(value)

const withoutPlanConfigChoices = (
  options: ReadonlyArray<SessionConfigOption>
): ReadonlyArray<SessionConfigOption> =>
  options.map((option) => (isModeOption(option) ? withoutPlanChoices(option) : option))

const withoutPlanChoices = (option: SessionConfigOption): SessionConfigOption => ({
  ...option,
  options: withoutPlanEntries(option.options)
})

const withoutPlanEntries = (
  entries: SessionConfigOption["options"]
): SessionConfigOption["options"] => {
  const groups = [...entries].filter(isGroup)
  if (groups.length > 0) {
    return groups.map((group) => ({ ...group, options: group.options.filter(isNotPlanChoice) }))
  }
  return [...entries].filter(isChoice).filter(isNotPlanChoice)
}

const isGroup = (
  entry: SessionConfigSelectOption | SessionConfigSelectGroup
): entry is SessionConfigSelectGroup => "group" in entry

const isChoice = (
  entry: SessionConfigSelectOption | SessionConfigSelectGroup
): entry is SessionConfigSelectOption => !("group" in entry)

const isNotPlanChoice = (choice: SessionConfigSelectOption): boolean =>
  !(isPlanModeId(choice.value) || planPattern.test(choice.name))
