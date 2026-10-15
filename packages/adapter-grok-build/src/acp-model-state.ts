import { isRecord } from "@codevisor/api"

import { record, type JsonRecord } from "./record.js"

interface AcpReasoningEffortOption {
  readonly id: string
  readonly value: string
  readonly name: string
  readonly description?: string
  readonly isDefault: boolean
}

export interface AcpReasoningEffortState {
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
  const raw: unknown = meta.reasoningEfforts
  if (!Array.isArray(raw)) return legacyReasoningEfforts()
  const entries: ReadonlyArray<unknown> = raw
  const parsed = entries.flatMap((option): Array<AcpReasoningEffortOption> => {
    if (typeof option === "string") {
      const value = canonicalReasoningEffort(option)
      return value === undefined
        ? []
        : [{ id: value, value, name: reasoningEffortName(value), isDefault: false }]
    }
    if (!isRecord(option)) return []
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
  if (!isRecord(response)) return undefined
  const meta = response._meta
  if (!isRecord(meta)) return undefined
  const sessionConfig = meta["x.ai/sessionConfig"]
  if (!isRecord(sessionConfig)) return undefined
  const options: unknown = sessionConfig.options
  if (!Array.isArray(options)) return undefined
  const entries: ReadonlyArray<unknown> = options
  const selected = entries
    .filter(isRecord)
    .find((entry) => entry.category === "mode" && entry.selected === true)
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

const modelMetadata = (model: JsonRecord): Readonly<JsonRecord> | undefined =>
  record(model._meta ?? model.meta)

const decodedModelEntry = (
  model: JsonRecord,
  modelId: string,
  reasoning: AcpReasoningEffortState | undefined
): Array<AcpModelInfo> => [
  {
    modelId,
    name: typeof model.name === "string" ? model.name : modelId,
    ...(typeof model.description === "string" ? { description: model.description } : {}),
    ...(reasoning === undefined ? {} : { reasoning })
  }
]

const availableModelEntry = (
  entry: unknown,
  currentModelId: string,
  selectedReasoningOptionId: string | undefined
): Array<AcpModelInfo> => {
  if (!isRecord(entry)) {
    return []
  }
  const modelId = entry.modelId
  if (typeof modelId !== "string") {
    return []
  }
  const meta = modelMetadata(entry)
  const reasoning = reasoningStateFromMeta(
    meta,
    modelId === currentModelId ? selectedReasoningOptionId : undefined
  )
  return decodedModelEntry(entry, modelId, reasoning)
}

const admittedModels = (response: unknown): JsonRecord | undefined =>
  isRecord(response) ? record(response.models) : undefined

export const extractAcpModelState = (response: unknown): AcpModelState | undefined => {
  const models = admittedModels(response)
  if (models === undefined) {
    return undefined
  }
  const currentModelId = models.currentModelId
  const rawAvailable: unknown = models.availableModels
  if (typeof currentModelId !== "string" || !Array.isArray(rawAvailable)) {
    return undefined
  }
  const selectedReasoningOptionId = selectedGrokReasoningOptionId(response)
  const availableModels = rawAvailable.flatMap((entry) =>
    availableModelEntry(entry, currentModelId, selectedReasoningOptionId)
  )
  if (availableModels.length === 0) {
    return undefined
  }
  return { availableModels, currentModelId }
}
