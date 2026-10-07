import type { SessionConfigOption } from "@codevisor/api"

/// Pi's models and thinking levels as Codevisor config options.

export interface PiModel {
  readonly id: string
  readonly name?: string
  readonly provider: string
  readonly contextWindow?: number
  readonly reasoning?: boolean
}

export const MODEL_OPTION_ID = "model"
export const THINKING_OPTION_ID = "thought_level"

/// `provider/id`: unique across providers, and how Pi names a model.
export const modelValue = (model: Pick<PiModel, "id" | "provider">): string =>
  `${model.provider}/${model.id}`

export const parseModelValue = (
  value: string
): { provider: string; modelId: string } | undefined => {
  const separator = value.indexOf("/")
  return separator <= 0 || separator === value.length - 1
    ? undefined
    : { provider: value.slice(0, separator), modelId: value.slice(separator + 1) }
}

const words: Record<string, string> = {
  ai: "AI",
  api: "API",
  github: "GitHub",
  openai: "OpenAI",
  openrouter: "OpenRouter",
  xai: "xAI"
}

/// A readable provider name from Pi's provider id ("openai-codex" → "OpenAI Codex").
export const providerName = (provider: string): string =>
  provider
    .split(/[-_]/)
    .filter((word) => word.length > 0)
    .map((word) => words[word] ?? `${word[0]!.toUpperCase()}${word.slice(1)}`)
    .join(" ")

const levelNames: Record<string, string> = {
  off: "Off",
  minimal: "Minimal",
  low: "Low",
  medium: "Medium",
  high: "High",
  xhigh: "Extra High",
  max: "Max"
}

export const configOptions = (state: {
  readonly models: ReadonlyArray<PiModel>
  readonly model: PiModel | undefined
  readonly levels: ReadonlyArray<string>
  readonly level: string | undefined
}): Array<SessionConfigOption> => {
  const options: Array<SessionConfigOption> = []
  if (state.models.length > 0) {
    const providers = [...new Set(state.models.map((model) => model.provider))]
    const choice = (model: PiModel) => ({ value: modelValue(model), name: model.name ?? model.id })
    options.push({
      id: MODEL_OPTION_ID,
      name: "Model",
      category: "model",
      currentValue:
        state.model === undefined ? modelValue(state.models[0]!) : modelValue(state.model),
      options:
        providers.length === 1
          ? state.models.map(choice)
          : providers.map((provider) => ({
              group: provider,
              name: providerName(provider),
              options: state.models.filter((model) => model.provider === provider).map(choice)
            }))
    })
  }
  if (state.levels.length > 0) {
    options.push({
      id: THINKING_OPTION_ID,
      name: "Thinking",
      category: "thought_level",
      currentValue: state.level ?? state.levels[0]!,
      options: state.levels.map((level) => ({ value: level, name: levelNames[level] ?? level }))
    })
  }
  return options
}
