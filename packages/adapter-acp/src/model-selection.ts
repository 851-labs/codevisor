import type * as acp from "@agentclientprotocol/sdk"
import type { SessionConfigOption } from "@codevisor/api"

/// The synthesized config-option id for the ACP model-selection extension.
/// Agents that report `session/new.models` (e.g. grok) expose their model list
/// via this optional extension rather than a `configOptions` entry, and apply a
/// change through `session/set_model` — NOT `session/set_config_option` (which
/// grok doesn't implement at all). `setConfigOption` routes this id accordingly.
export const acpModelConfigId = "model"
export const acpReasoningEffortConfigId = "reasoning_effort"

interface AcpReasoningEffortOption {
  readonly id: string
  readonly value: string
  readonly name: string
  readonly description?: string
  readonly isDefault: boolean
}

interface AcpReasoningEffortState {
  readonly options: ReadonlyArray<AcpReasoningEffortOption>
  readonly currentOptionId: string
}

interface AcpModelInfo {
  readonly modelId: string
  readonly name: string
  readonly description?: string
  readonly reasoning?: AcpReasoningEffortState
}

export interface AcpModelState {
  readonly currentModelId: string
  readonly availableModels: ReadonlyArray<AcpModelInfo>
}

const canonicalReasoningEffort = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const normalized = value.toLowerCase()
  if (normalized === "max") return "xhigh"
  return ["none", "minimal", "low", "medium", "high", "xhigh"].includes(normalized)
    ? normalized
    : undefined
}

const reasoningEffortName = (value: string): string => {
  switch (value) {
    case "xhigh":
      return "X-High"
    default:
      return `${value.slice(0, 1).toUpperCase()}${value.slice(1)}`
  }
}

const reasoningEffortDisplayName = (label: unknown, value: string): string => {
  if (typeof label !== "string" || label === "") return reasoningEffortName(value)
  const concise = label.replace(/\s+effort$/i, "").trim()
  return concise === "" ? label : concise
}

const legacyReasoningEfforts = (): ReadonlyArray<AcpReasoningEffortOption> =>
  ["minimal", "low", "medium", "high", "xhigh"].map((value) => ({
    id: value,
    value,
    name: reasoningEffortName(value),
    isDefault: false
  }))

const parseReasoningEffortOptions = (
  meta: Readonly<Record<string, unknown>>
): ReadonlyArray<AcpReasoningEffortOption> => {
  if (meta.supportsReasoningEffort !== true) return []
  const raw = meta.reasoningEfforts
  if (!Array.isArray(raw)) return legacyReasoningEfforts()
  const parsed = raw.flatMap((entry) => {
    if (typeof entry === "string") {
      const value = canonicalReasoningEffort(entry)
      return value === undefined
        ? []
        : [{ id: value, value, name: reasoningEffortName(value), isDefault: false }]
    }
    if (typeof entry !== "object" || entry === null) return []
    const option = entry as Record<string, unknown>
    const value = canonicalReasoningEffort(option.value)
    if (value === undefined) return []
    return [
      {
        id: typeof option.id === "string" && option.id !== "" ? option.id : value,
        value,
        name: reasoningEffortDisplayName(option.label, value),
        ...(typeof option.description === "string" ? { description: option.description } : {}),
        isDefault: option.default === true
      }
    ]
  })
  return parsed.length === 0 ? legacyReasoningEfforts() : parsed
}

const selectedGrokReasoningOptionId = (response: unknown): string | undefined => {
  if (typeof response !== "object" || response === null) return undefined
  const meta = (response as { readonly _meta?: unknown })._meta
  if (typeof meta !== "object" || meta === null) return undefined
  const sessionConfig = (meta as Record<string, unknown>)["x.ai/sessionConfig"]
  if (typeof sessionConfig !== "object" || sessionConfig === null) return undefined
  const options = (sessionConfig as Record<string, unknown>).options
  if (!Array.isArray(options)) return undefined
  const selected = options.find(
    (entry) =>
      typeof entry === "object" &&
      entry !== null &&
      (entry as Record<string, unknown>).category === "mode" &&
      (entry as Record<string, unknown>).selected === true
  ) as Record<string, unknown> | undefined
  return typeof selected?.id === "string" ? selected.id : undefined
}

const reasoningStateFromMeta = (
  meta: Readonly<Record<string, unknown>> | undefined,
  selectedOptionId?: string
): AcpReasoningEffortState | undefined => {
  if (meta === undefined) return undefined
  const options = parseReasoningEffortOptions(meta)
  if (options.length === 0) return undefined
  const currentEffort = canonicalReasoningEffort(meta.reasoningEffort)
  const currentOption =
    options.find((option) => option.id === selectedOptionId) ??
    options.find((option) => option.value === currentEffort) ??
    options.find((option) => option.isDefault) ??
    options[0]
  return currentOption === undefined ? undefined : { currentOptionId: currentOption.id, options }
}

/// Reads the optional ACP model-selection extension off a `session/new` (or
/// `session/load`) response. The field is not part of the SDK's typed schema,
/// so it arrives untyped — the SDK forwards the raw JSON-RPC result unparsed —
/// hence the defensive shape checks. Returns undefined when absent or malformed
/// so agents without the extension are left untouched (no empty picker).
export const extractAcpModelState = (response: unknown): AcpModelState | undefined => {
  if (typeof response !== "object" || response === null) {
    return undefined
  }
  const models = (response as { readonly models?: unknown }).models
  if (typeof models !== "object" || models === null) {
    return undefined
  }
  const currentModelId = (models as { readonly currentModelId?: unknown }).currentModelId
  const rawAvailable = (models as { readonly availableModels?: unknown }).availableModels
  if (typeof currentModelId !== "string" || !Array.isArray(rawAvailable)) {
    return undefined
  }
  const selectedReasoningOptionId = selectedGrokReasoningOptionId(response)
  const availableModels = rawAvailable.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) {
      return []
    }
    const model = entry as {
      readonly modelId?: unknown
      readonly name?: unknown
      readonly description?: unknown
      readonly _meta?: unknown
      readonly meta?: unknown
    }
    if (typeof model.modelId !== "string") {
      return []
    }
    const rawMeta = model._meta ?? model.meta
    const meta =
      typeof rawMeta === "object" && rawMeta !== null
        ? (rawMeta as Readonly<Record<string, unknown>>)
        : undefined
    const reasoning = reasoningStateFromMeta(
      meta,
      model.modelId === currentModelId ? selectedReasoningOptionId : undefined
    )
    return [
      {
        modelId: model.modelId,
        name: typeof model.name === "string" ? model.name : model.modelId,
        ...(typeof model.description === "string" ? { description: model.description } : {}),
        ...(reasoning === undefined ? {} : { reasoning })
      }
    ]
  })
  if (availableModels.length === 0) {
    return undefined
  }
  return { availableModels, currentModelId }
}

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

/// Grok applies a per-session effort by setting the current model again with
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
