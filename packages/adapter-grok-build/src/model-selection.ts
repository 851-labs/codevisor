import { isRecord } from "@codevisor/api"
import type { SessionConfigOption } from "@codevisor/api"

import type { AcpModelState, AcpReasoningEffortState } from "./acp-model-state.js"
import { record, type JsonRecord } from "./record.js"

export { extractAcpModelState, type AcpModelState } from "./acp-model-state.js"

export const acpModelConfigId = "model"
export const acpReasoningEffortConfigId = "reasoning_effort"

export const acpConfigOptionIds = (response: unknown): ReadonlySet<string> => {
  if (!isRecord(response)) return new Set()
  const options: unknown = response.configOptions
  if (!Array.isArray(options)) return new Set()
  const entries: ReadonlyArray<unknown> = options
  return new Set(
    entries.flatMap((option) => {
      if (!isRecord(option)) return []
      const id = option.id
      return typeof id === "string" ? [id] : []
    })
  )
}

export const usesAcpModelSelectionExtension = (
  configId: string,
  nativeConfigIds: ReadonlySet<string> | undefined
): boolean => configId === acpModelConfigId && !nativeConfigIds?.has(acpModelConfigId)

export const usesAcpReasoningEffortExtension = (
  configId: string,
  nativeConfigIds: ReadonlySet<string> | undefined
): boolean =>
  configId === acpReasoningEffortConfigId && !nativeConfigIds?.has(acpReasoningEffortConfigId)

export const acpModelConfigOption = (state: AcpModelState): SessionConfigOption => ({
  category: "model",
  currentValue: state.currentModelId,
  id: acpModelConfigId,
  name: "Model",
  options: state.availableModels.map((model) => ({
    value: model.modelId,
    name: model.name,
    ...(model.description === undefined ? {} : { description: model.description })
  }))
})

export const acpReasoningEffortConfigOption = (
  state: AcpModelState
): SessionConfigOption | undefined => {
  const current = state.availableModels.find((model) => model.modelId === state.currentModelId)
  const reasoning = current?.reasoning
  if (reasoning === undefined) return undefined
  return {
    category: "thought_level",
    currentValue: reasoning.currentOptionId,
    id: acpReasoningEffortConfigId,
    name: "Reasoning",
    options: reasoning.options.map((option) => ({
      value: option.id,
      name: option.name,
      ...(option.description === undefined ? {} : { description: option.description })
    }))
  }
}

const acpModelConfigOptions = (state: AcpModelState): ReadonlyArray<SessionConfigOption> => {
  const reasoning = acpReasoningEffortConfigOption(state)
  return reasoning === undefined
    ? [acpModelConfigOption(state)]
    : [acpModelConfigOption(state), reasoning]
}

export const mergeAcpModelConfigOptions = (
  configOptions: ReadonlyArray<SessionConfigOption>,
  modelState: AcpModelState | undefined
): ReadonlyArray<SessionConfigOption> => {
  if (modelState === undefined) return configOptions
  const merged = [...configOptions]
  if (!merged.some((option) => option.category === "model")) {
    merged.push(acpModelConfigOption(modelState))
  }
  const reasoning = acpReasoningEffortConfigOption(modelState)
  const hasNativeReasoning = merged.some((option) => option.id === acpReasoningEffortConfigId)
  if (reasoning !== undefined && !hasNativeReasoning) {
    merged.push(reasoning)
  }
  return merged
}

export interface AcpModelRequester {
  readonly agent: { readonly request: (method: string, params: unknown) => Promise<unknown> }
}

const setModelOutcome = (result: unknown): JsonRecord | undefined => {
  const meta = isRecord(result) ? record(result._meta) : undefined
  return record(meta?.model)
}

export const applyAcpModelSelection = async (
  connection: AcpModelRequester,
  modelStates: Map<string, AcpModelState>,
  sessionId: string,
  modelId: string
): Promise<ReadonlyArray<SessionConfigOption>> => {
  const result: unknown = await connection.agent.request("session/set_model", {
    modelId,
    sessionId
  })
  const outcome = setModelOutcome(result)
  if (outcome?.Err !== undefined) {
    const detail = typeof outcome.Err === "string" ? outcome.Err : JSON.stringify(outcome.Err)
    throw new Error(`session/set_model failed: ${detail}`)
  }
  const currentModelId = typeof outcome?.Ok === "string" ? outcome.Ok : modelId
  const existing = modelStates.get(sessionId)
  const state: AcpModelState = {
    availableModels:
      existing === undefined
        ? [{ modelId: currentModelId, name: currentModelId }]
        : existing.availableModels,
    currentModelId
  }
  modelStates.set(sessionId, state)
  return acpModelConfigOptions(state)
}

export const applyAcpReasoningEffortSelection = async (
  connection: AcpModelRequester,
  modelStates: Map<string, AcpModelState>,
  sessionId: string,
  optionId: string
): Promise<ReadonlyArray<SessionConfigOption>> => {
  const existing = modelStates.get(sessionId)
  const current = existing?.availableModels.find(
    (model) => model.modelId === existing.currentModelId
  )
  const selected = current?.reasoning?.options.find((option) => option.id === optionId)
  if (existing === undefined || current === undefined || selected === undefined) {
    throw new Error(`Unknown reasoning effort option: ${optionId}`)
  }
  const result: unknown = await connection.agent.request("session/set_model", {
    _meta: { reasoningEffort: selected.value },
    modelId: existing.currentModelId,
    sessionId
  })
  const outcome = setModelOutcome(result)
  if (outcome?.Err !== undefined) {
    const detail = typeof outcome.Err === "string" ? outcome.Err : JSON.stringify(outcome.Err)
    throw new Error(`session/set_model failed: ${detail}`)
  }
  const reasoning: AcpReasoningEffortState = {
    currentOptionId: selected.id,
    options: current.reasoning!.options
  }
  const state: AcpModelState = {
    currentModelId: existing.currentModelId,
    availableModels: existing.availableModels.map((model) =>
      model.modelId === existing.currentModelId ? { ...model, reasoning } : model
    )
  }
  modelStates.set(sessionId, state)
  return acpModelConfigOptions(state)
}
