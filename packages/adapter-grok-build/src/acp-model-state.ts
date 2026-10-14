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

interface RawAcpModelInfo {
  readonly modelId?: unknown
  readonly name?: unknown
  readonly description?: unknown
  readonly _meta?: unknown
  readonly meta?: unknown
}

const modelMetadata = (model: RawAcpModelInfo): Readonly<Record<string, unknown>> | undefined => {
  const rawMeta = model._meta ?? model.meta
  return typeof rawMeta === "object" && rawMeta !== null
    ? (rawMeta as Readonly<Record<string, unknown>>)
    : undefined
}

const decodedModelEntry = (
  model: RawAcpModelInfo,
  reasoning: AcpReasoningEffortState | undefined
): Array<AcpModelInfo> => [
  {
    modelId: model.modelId as string,
    name: typeof model.name === "string" ? model.name : (model.modelId as string),
    ...(typeof model.description === "string" ? { description: model.description } : {}),
    ...(reasoning === undefined ? {} : { reasoning })
  }
]

const availableModelEntry = (
  entry: unknown,
  currentModelId: string,
  selectedReasoningOptionId: string | undefined
): Array<AcpModelInfo> => {
  if (typeof entry !== "object" || entry === null) {
    return []
  }
  const model = entry as RawAcpModelInfo
  if (typeof model.modelId !== "string") {
    return []
  }
  const meta = modelMetadata(model)
  const reasoning = reasoningStateFromMeta(
    meta,
    model.modelId === currentModelId ? selectedReasoningOptionId : undefined
  )
  return decodedModelEntry(model, reasoning)
}

const admittedModels = (response: unknown): object | undefined => {
  if (typeof response !== "object" || response === null) {
    return undefined
  }
  const models = (response as { readonly models?: unknown }).models
  if (typeof models !== "object" || models === null) {
    return undefined
  }
  return models
}

export const extractAcpModelState = (response: unknown): AcpModelState | undefined => {
  const models = admittedModels(response)
  if (models === undefined) {
    return undefined
  }
  const currentModelId = (models as { readonly currentModelId?: unknown }).currentModelId
  const rawAvailable = (models as { readonly availableModels?: unknown }).availableModels
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
