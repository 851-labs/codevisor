import type * as acp from "@agentclientprotocol/sdk"
import type { SessionConfigOption } from "@codevisor/api"

import type { AcpModelState, AcpReasoningEffortState } from "./acp-model-state.js"

export { extractAcpModelState, type AcpModelState } from "./acp-model-state.js"

/// The synthesized config-option id for Grok's ACP model-selection extension.
/// Grok reports `session/new.models` and, since 1.0.24, also a native
/// `configOptions` list (`model` + `reasoning_effort`). When a native option
/// is present, changes go through `session/set_config_option`. The models
/// extension (`session/set_model`, including `_meta.reasoningEffort`) is
/// only used to fill a gap the CLI has not advertised yet.
export const acpModelConfigId = "model"
export const acpReasoningEffortConfigId = "reasoning_effort"

export const acpConfigOptionIds = (response: unknown): ReadonlySet<string> => {
  if (typeof response !== "object" || response === null) return new Set()
  const options = (response as { readonly configOptions?: unknown }).configOptions
  if (!Array.isArray(options)) return new Set()
  return new Set(
    options.flatMap((option) => {
      if (typeof option !== "object" || option === null) return []
      const id = (option as { readonly id?: unknown }).id
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

/// Synthesizes the Codevisor `category: "model"` picker option from the ACP model
/// extension so clients render a model chip — mirroring the shape claude/codex
/// build for their native model pickers.
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

/// Overlays the models-extension pickers onto ACP `configOptions` only when
/// the CLI omitted them. Grok 1.0.24+ already ships native `model` and
/// `reasoning_effort` selects; those stay authoritative so a later
/// `config_option_update` (the live effort menu after a model switch) is
/// not replaced by a cached overlay. Thought-level labels are canonicalized
/// by `normalizeAcpConfigOptions` at every ACP ingress.
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

/// `session/set_model` answers with a Rust-style `Result` under `_meta.model`
/// (`{ Ok: modelId }` on success, `{ Err }` on failure).
interface AcpSetModelResult {
  readonly _meta?: {
    readonly model?: { readonly Ok?: unknown; readonly Err?: unknown }
  }
}

/// Applies a model choice via the ACP model-selection setter and returns the
/// refreshed config options to broadcast. An `Err` result throws so the client
/// surfaces the failure instead of silently keeping the wrong model. Resumed
/// sessions may have no cached model list (load didn't report one) — fall back
/// to a single-entry option for the confirmed model so the chip still tracks it.
export const applyAcpModelSelection = async (
  connection: acp.ClientConnection,
  modelStates: Map<string, AcpModelState>,
  sessionId: string,
  modelId: string
): Promise<ReadonlyArray<SessionConfigOption>> => {
  const result = (await connection.agent.request("session/set_model", {
    modelId,
    sessionId
  })) as AcpSetModelResult
  const outcome = result?._meta?.model
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

/// Fallback for CLIs that have no native `reasoning_effort` option: Grok
/// applies a per-session effort by setting the current model again with
/// `_meta.reasoningEffort`. The picker value is the server-defined option id;
/// the request carries its canonical value so custom ids such as `deep` map to
/// the xAI wire value (`xhigh`) correctly.
export const applyAcpReasoningEffortSelection = async (
  connection: acp.ClientConnection,
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
  const result = (await connection.agent.request("session/set_model", {
    _meta: { reasoningEffort: selected.value },
    modelId: existing.currentModelId,
    sessionId
  })) as AcpSetModelResult
  const outcome = result?._meta?.model
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
